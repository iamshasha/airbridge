package app.airbridge.android

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.ParcelUuid
import app.airbridge.core.DiscoverySource
import app.airbridge.core.Endpoint
import app.airbridge.core.Node
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/** IPv4 addresses of this phone's active interfaces (Wi-Fi, Ethernet, hotspot, VPN). */
internal fun localAddresses(): List<String> = runCatching {
    NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
        .flatMap { it.inetAddresses.toList() }.filterIsInstance<Inet4Address>().map { it.hostAddress!! }
}.getOrDefault(emptyList())

/**
 * Bonjour-compatible `_airbridge._tcp` discovery through Android's NSD (PROTOCOL.md §1).
 * Service name = device id; TXT carries id, name, fingerprint and platform.
 */
class NsdDiscovery(context: Context, private val node: Node) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val resolveLock = Mutex()
    private val lostTimers = ConcurrentHashMap<String, Job>()
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null

    fun start(port: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = node.identity.id
            serviceType = TYPE
            this.port = port
            setAttribute("id", node.identity.id)
            setAttribute("n", node.settings.value.deviceName)
            setAttribute("fp", node.identity.fingerprint)
            setAttribute("pl", node.platform)
            setAttribute("v", "1")
        }
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }.also { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, it) }

        discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {}
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceName == node.identity.id) return
                lostTimers.remove(info.serviceName)?.cancel()
                scope.launch { resolve(info) }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                // Grace period: mDNS often reports a device lost and found again within seconds.
                val id = info.serviceName
                lostTimers[id] = scope.launch { delay(8_000); node.removeSource(id, DiscoverySource.Lan) }
            }
        }.also { nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, it) }
    }

    /** Re-announce after a rename or a new port. */
    fun restart(port: Int) { stop(); start(port) }

    fun stop() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        registration = null
        discovery = null
    }

    /** NSD resolves one service at a time before Android 14, so resolutions are queued. */
    @Suppress("DEPRECATION")
    private suspend fun resolve(found: NsdServiceInfo) = resolveLock.withLock {
        val info = suspendCoroutine<NsdServiceInfo?> { cont ->
            nsd.resolveService(found, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, code: Int) = cont.resume(null)
                override fun onServiceResolved(info: NsdServiceInfo) = cont.resume(info)
            })
        } ?: return@withLock
        val txt = info.attributes.mapValues { (_, v) -> v?.decodeToString() }
        val id = txt["id"] ?: info.serviceName
        val hosts = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
        val endpoints = hosts.mapNotNull { it.hostAddress?.substringBefore('%') }.map { Endpoint(it, info.port) }
        if (endpoints.isEmpty()) return@withLock
        node.updatePeer(id, txt["n"] ?: info.serviceName, txt["pl"] ?: "mac", txt["fp"], DiscoverySource.Lan, endpoints)
    }

    companion object {
        const val TYPE = "_airbridge._tcp"
    }
}

/**
 * Bluetooth LE discovery (PROTOCOL.md §1): advertise our card over GATT, scan for others and read theirs.
 * Finds devices when Wi-Fi multicast is blocked; the transfer itself still goes over TCP.
 */
@SuppressLint("MissingPermission") // callers check permissions via BluetoothDiscovery.permitted
class BluetoothDiscovery(private val context: Context, private val node: Node) {
    @Serializable
    private data class Card(val id: String, val n: String, val fp: String, val pl: String, val p: Int, val a: List<String>)

    private val json = Json { ignoreUnknownKeys = true }
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private val lastRead = ConcurrentHashMap<String, Long>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val advertiseCallback = object : AdvertiseCallback() {}
    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = read(result.device, result.rssi)
        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { read(it.device, it.rssi) }
    }

    private fun card(): ByteArray = json.encodeToString(Card.serializer(), Card(
        node.identity.id, node.settings.value.deviceName, node.identity.fingerprint, node.platform,
        node.listeningPort.value ?: 0, localAddresses(),
    )).toByteArray()

    fun start() {
        val adapter = manager?.adapter ?: return
        if (!adapter.isEnabled || !permitted(context)) return
        runCatching { startServer() }
        runCatching {
            adapter.bluetoothLeAdvertiser?.startAdvertising(
                AdvertiseSettings.Builder().setConnectable(true).setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED).build(),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build(),
                advertiseCallback,
            )
        }
        runCatching {
            adapter.bluetoothLeScanner?.startScan(
                listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(),
                scanCallback,
            )
        }
    }

    fun stop() {
        val adapter = manager?.adapter ?: return
        if (!permitted(context)) return
        runCatching { adapter.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        runCatching { adapter.bluetoothLeScanner?.stopScan(scanCallback) }
        runCatching { server?.close() }
        server = null
    }

    private fun startServer() {
        val characteristic = BluetoothGattCharacteristic(CARD, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ)
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY).apply { addCharacteristic(characteristic) }
        server = manager.openGattServer(context, object : BluetoothGattServerCallback() {
            override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, c: BluetoothGattCharacteristic) {
                // Long reads arrive in pieces; answer each from the requested offset.
                val value = card()
                val slice = if (offset < value.size) value.copyOfRange(offset, value.size) else ByteArray(0)
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
            }
        })?.also { it.addService(service) }
    }

    /** Reads a device's card at most once a minute. */
    private fun read(device: BluetoothDevice, rssi: Int) {
        val now = System.currentTimeMillis()
        val previous = lastRead[device.address]
        if (previous != null && now - previous < 60_000) return
        lastRead[device.address] = now
        scope.launch {
            device.connectGatt(context, false, object : BluetoothGattCallback() {
                override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                    if (newState == BluetoothProfile.STATE_CONNECTED) gatt.requestMtu(512)
                    else if (newState == BluetoothProfile.STATE_DISCONNECTED) gatt.close()
                }
                override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) { gatt.discoverServices() }
                override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                    val c = gatt.getService(SERVICE)?.getCharacteristic(CARD)
                    if (c == null) gatt.disconnect() else gatt.readCharacteristic(c)
                }
                @Deprecated("Deprecated in Java")
                @Suppress("DEPRECATION")
                override fun onCharacteristicRead(gatt: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
                    handleCard(c.value, rssi); gatt.disconnect()
                }
                override fun onCharacteristicRead(gatt: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
                    handleCard(value, rssi); gatt.disconnect()
                }
            }, BluetoothDevice.TRANSPORT_LE)
        }
    }

    private fun handleCard(value: ByteArray?, rssi: Int) {
        val card = value?.let { runCatching { json.decodeFromString(Card.serializer(), it.decodeToString()) }.getOrNull() } ?: return
        if (card.p == 0) return
        node.updatePeer(card.id, card.n, card.pl, card.fp, DiscoverySource.Bluetooth, card.a.map { Endpoint(it, card.p) }, rssi)
    }

    companion object {
        val SERVICE: UUID = UUID.fromString("5A1B0001-6A3F-4E8E-9D2C-A1B2C3D4E5F6")
        val CARD: UUID = UUID.fromString("5A1B0002-6A3F-4E8E-9D2C-A1B2C3D4E5F6")

        val permissions = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)

        fun permitted(context: Context) = Build.VERSION.SDK_INT < 31 ||
            permissions.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }
}
