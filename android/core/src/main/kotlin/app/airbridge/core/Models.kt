package app.airbridge.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

@Serializable
data class TrustedDevice(
    val id: String,
    val name: String,
    val fingerprint: String,
    val platform: String = "mac",
    val addedAt: Long = System.currentTimeMillis(),
    /** Accept incoming files without asking (auto download). */
    val autoAccept: Boolean = true,
    /** May list and pull from our shared folder. */
    val allowBrowse: Boolean = true,
    /** Put received text straight on the clipboard. */
    val autoClipboard: Boolean = false,
    val lastHost: String? = null,
    val lastPort: Int? = null,
)

@Serializable
enum class ReceivePolicy { Everyone, TrustedOnly, Off }

/** Watched local folder pushed automatically to a trusted device (auto upload). */
@Serializable
data class SyncRule(val deviceId: String, val folder: String, val id: String = UUID.randomUUID().toString(), val enabled: Boolean = true)

@Serializable
data class Settings(
    val deviceName: String = "Android",
    val receivePolicy: ReceivePolicy = ReceivePolicy.Everyone,
    val downloadFolder: String = "",
    val sharedFolder: String? = null,
    val port: Int = 47820,
    val parallelStreams: Int = 4,
    val bluetoothDiscovery: Boolean = true,
    val syncRules: List<SyncRule> = emptyList(),
    val relayUrl: String = "",
    /** MB/s or Mbps for every speed shown. */
    val speedUnit: SpeedUnit = SpeedUnit.Bytes,
)

enum class DiscoverySource(val label: String) {
    Lan("Wi-Fi"), PeerToPeer("Peer-to-peer Wi-Fi"), Bluetooth("Bluetooth"), Manual("Added by address"), Trusted("Last known address")
}

data class Endpoint(val host: String, val port: Int)

/** A device we can see or have paired with. Immutable snapshot; the node replaces it on change. */
data class Peer(
    val id: String,
    val name: String = "",
    val platform: String = "mac",
    val fingerprint: String? = null,
    val endpoints: Map<DiscoverySource, List<Endpoint>> = emptyMap(),
    val lastSeen: Long = System.currentTimeMillis(),
    val rssi: Int? = null,
) {
    val sources: List<DiscoverySource> get() = endpoints.filterValues { it.isNotEmpty() }.keys.sorted()
    val isOnline: Boolean get() = sources.any { it != DiscoverySource.Trusted }

    /** Fastest first: LAN, peer-to-peer, manual, Bluetooth-learned addresses, last known. */
    val orderedEndpoints: List<Endpoint>
        get() = listOf(DiscoverySource.Lan, DiscoverySource.PeerToPeer, DiscoverySource.Manual, DiscoverySource.Bluetooth, DiscoverySource.Trusted)
            .flatMap { endpoints[it].orEmpty() }.distinct()

    companion object {
        fun at(host: String, port: Int, id: String = "", name: String = "") =
            Peer(id = id, name = name, endpoints = mapOf(DiscoverySource.Manual to listOf(Endpoint(host, port))))
    }
}

enum class TransferDirection { Outgoing, Incoming }
enum class TransferState { Connecting, WaitingForAcceptance, Active, Done, Failed, Declined;
    val isFinished get() = this == Done || this == Failed || this == Declined
}

/** Progress of one transfer, as shown in the UI. */
data class Transfer(
    val id: String,
    val direction: TransferDirection,
    val peerName: String,
    val title: String,
    val total: Long,
    val sync: Boolean = false,
    val state: TransferState = TransferState.Connecting,
    val bytes: Long = 0,
    val bytesPerSecond: Double = 0.0,
    val error: String? = null,
    val savedPaths: List<String> = emptyList(),
    val startedAt: Long = System.currentTimeMillis(),
    val finishedAt: Long? = null,
) {
    val fraction: Float get() = if (total > 0) (bytes.toDouble() / total).coerceAtMost(1.0).toFloat() else if (state == TransferState.Done) 1f else 0f
    val isFinished get() = state.isFinished
}

data class ReceivedText(val from: String, val text: String, val id: String = UUID.randomUUID().toString(), val date: Long = System.currentTimeMillis())

enum class PromptKind { Offer, Pairing }

/** Something the user decides: an incoming offer or a pairing request. */
data class PromptRequest(
    val peerName: String,
    val peerPlatform: String,
    val fingerprint: String,
    val kind: PromptKind,
    val items: List<FileItem> = emptyList(),
    val total: Long = 0,
    val code: String? = null,
    val id: String = UUID.randomUUID().toString(),
) {
    val title: String get() = titleOf(items)
    val summary: String
        get() = if (kind == PromptKind.Pairing) "$peerName wants to pair" else "$peerName wants to send $title (${formatBytes(total.toDouble())})"
}

/** JSON files under the app's data folder. */
class Store(val directory: File) {
    init { directory.mkdirs() }

    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true; encodeDefaults = true }

    fun <T> load(serializer: KSerializer<T>, name: String): T? =
        runCatching { json.decodeFromString(serializer, File(directory, name).readText()) }.getOrNull()

    fun <T> save(serializer: KSerializer<T>, value: T, name: String) {
        val target = File(directory, name)
        val temp = File(directory, "$name.tmp")
        temp.writeText(json.encodeToString(serializer, value))
        if (!temp.renameTo(target)) { target.delete(); temp.renameTo(target) }
    }

    fun remove(name: String) { File(directory, name).delete() }
}

private val units = listOf("bytes", "KB", "MB", "GB", "TB")

/** Decimal units like Finder and the Swift ByteCountFormatter (1 KB = 1000 bytes). */
fun formatBytes(value: Double): String {
    var bytes = value
    var unit = 0
    while (bytes >= 1000 && unit < units.size - 1) { bytes /= 1000; unit++ }
    return if (unit == 0) "${bytes.toLong()} ${units[0]}" else "${"%.1f".format(bytes).removeSuffix(".0")} ${units[unit]}"
}
