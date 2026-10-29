package app.airbridge.android

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.provider.Settings as SystemSettings
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import app.airbridge.core.AirBridgeError
import app.airbridge.core.AirBridgeException
import app.airbridge.core.OutgoingItems
import app.airbridge.core.Peer
import app.airbridge.core.RemoteEntry
import app.airbridge.core.Store
import app.airbridge.core.TransferDirection
import app.airbridge.core.TransferState
import app.airbridge.core.Node
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.nio.channels.FileChannel

class AirBridgeApplication : Application() {
    lateinit var airBridge: AirBridge; private set

    override fun onCreate() {
        super.onCreate()
        airBridge = AirBridge(this)
    }
}

val Context.airBridge: AirBridge get() = (applicationContext as AirBridgeApplication).airBridge

/** Something the UI acknowledges with a banner and a haptic. */
data class Feedback(val text: String?, val kind: Kind, val id: Long = System.nanoTime()) {
    enum class Kind { Success, Arrival, Warning, Error, Crisp }
}

/** Files or text handed to AirBridge from another app's share sheet, waiting for a destination. */
data class PendingShare(val uris: List<Uri> = emptyList(), val text: String? = null)

data class PairingCode(val peer: String, val code: String)

data class SharedLink(val title: String, val link: String? = null, val finished: Boolean = false)

/**
 * App-wide state for phones, tablets and foldables: the engine plus discovery, clipboard, notifications
 * and the background service. Lives as long as the process.
 */
class AirBridge(private val app: Application) {
    val node: Node = Node(
        Store(File(app.filesDir, "state")),
        defaultName = SystemSettings.Global.getString(app.contentResolver, SystemSettings.Global.DEVICE_NAME) ?: Build.MODEL,
        platform = "android",
        defaultDownloads = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "AirBridge"),
    )
    private val nsd = NsdDiscovery(app, node)
    private val bluetooth = BluetoothDiscovery(app, node)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val prefs = app.getSharedPreferences("app", Context.MODE_PRIVATE)
    val notifications = Notifications(app)
    val updater = Updater(app)

    private val _feedback = MutableSharedFlow<Feedback>(extraBufferCapacity = 8)
    val feedback = _feedback.asSharedFlow()
    val error = MutableStateFlow<String?>(null)
    val pairingCode = MutableStateFlow<PairingCode?>(null)
    val sharedLink = MutableStateFlow<SharedLink?>(null)
    val pendingShare = MutableStateFlow<PendingShare?>(null)
    /** A received file to open (from a notification). */
    val openRequest = MutableStateFlow<File?>(null)

    private val _keepRunning = MutableStateFlow(prefs.getBoolean("keepRunning", true))
    /** Keep receiving with the app closed (a foreground service with a quiet notification). */
    val keepRunning = _keepRunning.asStateFlow()

    private var started = false

    val isForeground get() = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)

    init {
        if (node.settings.value.sharedFolder == null)
            node.updateSettings { it.copy(sharedFolder = app.getExternalFilesDir("Shared")?.apply { mkdirs() }?.path) }
        node.onPrompt = { prompt -> if (!isForeground) notifications.prompt(prompt) }
        node.onTextReceived = { item, toClipboard ->
            scope.launch {
                if (toClipboard) app.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("AirBridge", item.text))
                signal(Feedback("Text from ${item.from}", Feedback.Kind.Arrival))
                if (!isForeground) notifications.text(item, toClipboard)
            }
        }
        node.onTransferFinished = { record ->
            scope.launch {
                when (record.state) {
                    TransferState.Done -> if (record.direction == TransferDirection.Incoming) {
                        scanIntoMediaStore(record.savedPaths)
                        signal(Feedback("Received ${record.title}", Feedback.Kind.Success))
                        if (!isForeground) notifications.received(record)
                    } else {
                        signal(Feedback("Sent to ${record.peerName}", Feedback.Kind.Success))
                    }
                    TransferState.Declined -> signal(Feedback("${record.peerName} declined", Feedback.Kind.Warning))
                    TransferState.Failed -> signal(Feedback(null, Feedback.Kind.Error))
                    else -> {}
                }
            }
        }
        node.onUnpairedByPeer = { name -> scope.launch { signal(Feedback("$name unpaired this device", Feedback.Kind.Warning)) } }
        // Drop answered requests from the notification shade.
        scope.launch {
            var shown = emptySet<String>()
            node.prompts.collect { list ->
                val now = list.map { it.id }.toSet()
                (shown - now).forEach(notifications::removePrompt)
                shown = now
            }
        }
    }

    /** Starts listening and discovery. Called once the user is past onboarding and permissions. */
    fun start() {
        if (started) { restartDiscovery(); return }
        started = true
        node.start()
        nsd.start(node.listeningPort.value ?: 0)
        if (node.settings.value.bluetoothDiscovery) bluetooth.start()
        if (keepRunning.value) AirBridgeService.start(app)
        updater.checkInBackground()
    }

    /** After a permission grant, a rename or a network change. */
    fun restartDiscovery() {
        node.republish()
        nsd.restart(node.listeningPort.value ?: 0)
        bluetooth.stop()
        if (node.settings.value.bluetoothDiscovery) bluetooth.start()
    }

    fun setKeepRunning(on: Boolean) {
        _keepRunning.value = on
        prefs.edit().putBoolean("keepRunning", on).apply()
        if (on) AirBridgeService.start(app) else AirBridgeService.stop(app)
    }

    fun setBluetooth(on: Boolean) {
        node.updateSettings { it.copy(bluetoothDiscovery = on) }
        if (on) bluetooth.start() else bluetooth.stop()
    }

    fun rename(name: String) {
        if (name.isBlank()) return
        node.updateSettings { it.copy(deviceName = name.trim()) }
        restartDiscovery()
    }

    fun signal(feedback: Feedback) { _feedback.tryEmit(feedback) }

    private fun report(e: Throwable, context: String) {
        signal(Feedback(null, Feedback.Kind.Error))
        error.value = when {
            e is AirBridgeException && e.kind == AirBridgeError.Declined -> "$context: the other device declined."
            else -> "$context: ${e.message ?: e.javaClass.simpleName}"
        }
    }

    // MARK: sending

    /** Content URIs from the picker or share sheet, read in place where the provider allows seeking. */
    private suspend fun outgoing(uris: List<Uri>): OutgoingItems = withContext(Dispatchers.IO) {
        val items = OutgoingItems()
        val taken = mutableSetOf<String>()
        for (uri in uris) {
            var name = "File"
            var size = -1L
            app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
            if (uri.scheme == "file") uri.path?.let { File(it) }?.let { name = it.name; size = it.length() }
            name = uniqueName(name.replace('/', '-'), taken)
            val pfd = app.contentResolver.openFileDescriptor(uri, "r")
            val seekable = pfd != null && pfd.statSize >= 0
            if (seekable && size >= 0) {
                pfd.close()
                items.addFile(name, size) { open(uri) }
            } else {
                // Pipes and virtual files can't be read at offsets: stage a copy first.
                pfd?.close()
                val copy = File(app.cacheDir, "outgoing/${System.nanoTime()}/$name").apply { parentFile!!.mkdirs() }
                app.contentResolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
                items.addFile(name, copy.length(), copy.path) { FileInputStream(copy).channel }
            }
        }
        items
    }

    private fun open(uri: Uri): FileChannel {
        val pfd = app.contentResolver.openFileDescriptor(uri, "r") ?: throw AirBridgeException(AirBridgeError.ProtocolViolation, "file is gone")
        return ParcelFileDescriptor.AutoCloseInputStream(pfd).channel
    }

    private fun uniqueName(name: String, taken: MutableSet<String>): String {
        var candidate = name
        var i = 2
        while (!taken.add(candidate)) {
            val dot = name.lastIndexOf('.').takeIf { it > 0 }
            candidate = if (dot != null) "${name.substring(0, dot)} ($i)${name.substring(dot)}" else "$name ($i)"
            i++
        }
        return candidate
    }

    fun send(uris: List<Uri>, peers: List<Peer>) {
        if (uris.isEmpty() || peers.isEmpty()) return
        scope.launch {
            val items = try { outgoing(uris) } catch (e: Exception) { report(e, "Reading the files"); return@launch }
            for (peer in peers) launch {
                try { node.send(items, peer) } catch (e: Exception) {
                    if (e is AirBridgeException && e.kind == AirBridgeError.Declined) return@launch // has its own banner
                    report(e, "Sending to ${peer.name}")
                }
            }
        }
    }

    fun sendText(text: String, peers: List<Peer>) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        for (peer in peers) scope.launch {
            try {
                node.sendText(trimmed, peer)
                signal(Feedback("Sent to ${peer.name}", Feedback.Kind.Success))
            } catch (e: Exception) { report(e, "Sending text to ${peer.name}") }
        }
    }

    fun sendClipboard(peers: List<Peer>) {
        val clip = app.getSystemService(ClipboardManager::class.java).primaryClip
        val item = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        when {
            item?.uri != null -> send(listOf(item.uri), peers)
            item?.text != null -> sendText(item.text.toString(), peers)
            else -> error.value = "The clipboard is empty."
        }
    }

    /** Sends whatever came from the share sheet to the chosen devices. */
    fun deliverPendingShare(peers: List<Peer>) {
        val share = pendingShare.value ?: return
        pendingShare.value = null
        if (share.uris.isNotEmpty()) send(share.uris, peers)
        share.text?.let { sendText(it, peers) }
    }

    fun pair(peer: Peer) {
        scope.launch {
            try {
                node.pair(peer) { code ->
                    pairingCode.value = PairingCode(peer.name, code)
                    signal(Feedback(null, Feedback.Kind.Crisp))
                }
                pairingCode.value = null
                signal(Feedback("Paired with ${peer.name}", Feedback.Kind.Success))
            } catch (e: Exception) {
                pairingCode.value = null
                report(e, "Pairing with ${peer.name}")
            }
        }
    }

    fun shareViaLink(uris: List<Uri>) {
        if (!node.relayConfigured) { error.value = "Add a relay address in Settings › Internet links to share links."; return }
        scope.launch {
            val items = try { outgoing(uris) } catch (e: Exception) { report(e, "Reading the files"); return@launch }
            sharedLink.value = SharedLink(items.title)
            try {
                node.shareViaLink(items) { link -> sharedLink.value = sharedLink.value?.copy(link = link) }
                sharedLink.value = sharedLink.value?.copy(finished = true)
            } catch (e: Exception) {
                sharedLink.value = null
                report(e, "Link transfer")
            }
        }
    }

    fun openLink(link: String) {
        scope.launch { try { node.openLink(link) } catch (e: Exception) { report(e, "Opening the link") } }
    }

    suspend fun addManualDevice(address: String): Peer? {
        val trimmed = address.trim()
        val host = trimmed.substringBeforeLast(':', trimmed).ifEmpty { trimmed }
        val port = trimmed.substringAfterLast(':', "").toIntOrNull() ?: 47820
        return try { node.addManualPeer(host, port) } catch (e: Exception) { report(e, "Connecting to $trimmed"); null }
    }

    suspend fun browse(peer: Peer, path: String): List<RemoteEntry>? =
        try { node.browse(peer, path) } catch (e: Exception) { report(e, "Browsing ${peer.name}"); null }

    fun pull(paths: List<String>, peer: Peer) {
        scope.launch { try { node.pull(paths, peer) } catch (e: Exception) { report(e, "Downloading from ${peer.name}") } }
    }

    // MARK: received files

    /** Makes received photos and videos show up in Gallery and Files right away. */
    private fun scanIntoMediaStore(paths: List<String>) {
        val files = paths.map(::File).flatMap { if (it.isDirectory) it.walkTopDown().filter(File::isFile).toList() else listOf(it) }
        if (files.isNotEmpty()) MediaScannerConnection.scanFile(app, files.map { it.path }.toTypedArray(), null, null)
    }

    /** Intent that opens a received file in the app that handles its type. */
    fun viewIntent(file: File): Intent = Intent(Intent.ACTION_VIEW).apply {
        val uri = androidx.core.content.FileProvider.getUriForFile(app, "app.airbridge.android.files", file)
        setDataAndType(uri, app.contentResolver.getType(uri) ?: mimeOf(file))
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    fun shareIntent(file: File): Intent = Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
        val uri = androidx.core.content.FileProvider.getUriForFile(app, "app.airbridge.android.files", file)
        type = mimeOf(file)
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}

internal fun mimeOf(file: File): String =
    android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
