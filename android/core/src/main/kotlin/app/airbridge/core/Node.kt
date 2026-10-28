package app.airbridge.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.URI
import java.net.URLDecoder
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The AirBridge engine for Android (and any JVM): listener, trust, and every flow in PROTOCOL.md.
 * State is exposed as [StateFlow]s; callbacks fire on background threads.
 */
class Node(private val store: Store, defaultName: String, val platform: String = "android", private val defaultDownloads: File) {
    val identity: DeviceIdentity = DeviceIdentity.loadOrCreate(File(store.directory, "identity.json"))

    private val _settings = MutableStateFlow(store.load(Settings.serializer(), "settings.json") ?: Settings(deviceName = defaultName))
    val settings: StateFlow<Settings> = _settings.asStateFlow()

    private val trustedSerializer = MapSerializer(String.serializer(), TrustedDevice.serializer())
    private val _trusted = MutableStateFlow(store.load(trustedSerializer, "trusted.json") ?: emptyMap())
    val trusted: StateFlow<Map<String, TrustedDevice>> = _trusted.asStateFlow()

    private val _peers = MutableStateFlow<Map<String, Peer>>(emptyMap())
    private val _peerList = MutableStateFlow<List<Peer>>(emptyList())
    /** Sorted by name only, so rows never jump around when a device comes and goes. */
    val peers: StateFlow<List<Peer>> = _peerList.asStateFlow()

    private val _transfers = MutableStateFlow<List<Transfer>>(emptyList())
    val transfers: StateFlow<List<Transfer>> = _transfers.asStateFlow()

    private val _inbox = MutableStateFlow<List<ReceivedText>>(emptyList())
    val inbox: StateFlow<List<ReceivedText>> = _inbox.asStateFlow()

    /** Requests waiting for the user, oldest first. Answer with [respond]. */
    private val _prompts = MutableStateFlow<List<PromptRequest>>(emptyList())
    val prompts: StateFlow<List<PromptRequest>> = _prompts.asStateFlow()
    private val decisions = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()

    private val _listeningPort = MutableStateFlow<Int?>(null)
    val listeningPort: StateFlow<Int?> = _listeningPort.asStateFlow()

    var onTextReceived: ((ReceivedText, Boolean) -> Unit)? = null
    var onTransferFinished: ((Transfer) -> Unit)? = null
    var onUnpairedByPeer: ((String) -> Unit)? = null
    var onPrompt: ((PromptRequest) -> Unit)? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var listener: ServerSocket? = null
    private val live = ConcurrentHashMap<String, Live>()
    private val active = ConcurrentHashMap<String, ActiveTransfer>()
    private val deliveringUnpairs = AtomicBoolean(false)
    private val syncBusy = ConcurrentHashMap.newKeySet<String>()

    init { rebuildTrustedPeers() }

    val local get() = SecureChannel.LocalInfo(identity, settings.value.deviceName, platform, listeningPort.value ?: 0)
    val downloadFolder get() = File(settings.value.downloadFolder.ifEmpty { defaultDownloads.path })

    fun updateSettings(change: (Settings) -> Settings) {
        _settings.update(change)
        store.save(Settings.serializer(), settings.value, "settings.json")
    }

    // MARK: lifecycle

    fun start(listen: Boolean = true) {
        if (listen) startListener()
        scope.launch { tickLoop() }
    }

    private fun startListener() {
        for (port in listOf(settings.value.port, 0)) {
            try {
                val server = ServerSocket()
                server.reuseAddress = true
                server.bind(InetSocketAddress(port), 64)
                listener = server
                _listeningPort.value = server.localPort
                scope.launch {
                    while (isActive) {
                        val socket = try { server.accept() } catch (e: IOException) { return@launch }
                        scope.launch { handleIncoming(TcpWire(socket)) }
                    }
                }
                return
            } catch (e: IOException) {
                if (port == 0) throw e // port taken: fall back to any free port
            }
        }
    }

    /** Restarts the listener after the OS tore it down (e.g. network change while in the background). */
    fun republish() {
        if (listener?.isClosed == false) return
        startListener()
    }

    private suspend fun tickLoop() {
        var lastSync = 0L
        while (scope.isActive) {
            delay(250)
            sampleProgress()
            if (System.currentTimeMillis() - lastSync > 5000) {
                lastSync = System.currentTimeMillis()
                scope.launch { deliverPendingUnpairs() }
                runSyncRules()
            }
        }
    }

    fun close() {
        scope.cancel()
        runCatching { listener?.close() }
    }

    // MARK: peers

    private fun publishPeers() {
        val sorted = _peers.value.values.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER, Peer::name).thenBy(Peer::id))
        if (sorted != _peerList.value) _peerList.value = sorted
    }

    fun peer(id: String): Peer? = _peers.value[id]

    /** Discovery sources report what they see here (NSD, Bluetooth). */
    fun updatePeer(id: String, name: String, platform: String, fingerprint: String?, source: DiscoverySource, endpoints: List<Endpoint>, rssi: Int? = null) {
        if (id == identity.id) return
        _peers.update { peers ->
            val old = peers[id] ?: Peer(id = id)
            peers + (id to old.copy(
                name = name, platform = platform, fingerprint = fingerprint ?: old.fingerprint,
                lastSeen = System.currentTimeMillis(), rssi = rssi ?: old.rssi, endpoints = old.endpoints + (source to endpoints),
            ))
        }
        publishPeers()
    }

    fun removeSource(id: String, source: DiscoverySource) {
        _peers.update { peers ->
            val peer = peers[id] ?: return@update peers
            val updated = peer.copy(endpoints = peer.endpoints - source)
            if (updated.sources.isEmpty() && id !in _trusted.value) peers - id else peers + (id to updated)
        }
        publishPeers()
    }

    /** Adds a device by address (VPN, routed network). Its identity is learned on first connect. */
    suspend fun addManualPeer(host: String, port: Int): Peer {
        val (channel, _) = connect(listOf(Endpoint(host, port)), null)
        channel.use {
            val hello = it.peer
            updatePeer(hello.id, hello.name, hello.platform, hello.fingerprint, DiscoverySource.Manual, listOf(Endpoint(host, port)))
            return peer(hello.id)!!
        }
    }

    private fun rebuildTrustedPeers() {
        _peers.update { peers ->
            val result = peers.toMutableMap()
            for (device in _trusted.value.values) {
                val old = result[device.id] ?: Peer(id = device.id, name = device.name, platform = device.platform)
                val endpoints = if (device.lastHost != null && device.lastPort != null)
                    old.endpoints + (DiscoverySource.Trusted to listOf(Endpoint(device.lastHost, device.lastPort)))
                else old.endpoints
                result[device.id] = old.copy(fingerprint = device.fingerprint, endpoints = endpoints)
            }
            result
        }
        publishPeers()
    }

    // MARK: trust

    fun isTrusted(peer: Peer): Boolean {
        val t = _trusted.value[peer.id] ?: return false
        return peer.fingerprint == null || peer.fingerprint == t.fingerprint
    }

    fun isOnline(peer: Peer) = peer.isOnline

    private fun trustedFor(hello: Hello) = _trusted.value[hello.id]?.takeIf { it.fingerprint == hello.fingerprint }

    fun updateTrusted(device: TrustedDevice) {
        _trusted.update { it + (device.id to device) }
        store.save(trustedSerializer, _trusted.value, "trusted.json")
        rebuildTrustedPeers()
    }

    /** Unpairs locally and tells the other device, now or the next time it is reachable. */
    fun unpair(id: String) {
        _trusted.value[id]?.let { device ->
            val pending = store.load(trustedSerializer, "pending-unpairs.json").orEmpty() + (id to device)
            store.save(trustedSerializer, pending, "pending-unpairs.json")
        }
        removeTrust(id)
        scope.launch { deliverPendingUnpairs() }
    }

    private fun removeTrust(id: String) {
        _trusted.update { it - id }
        store.save(trustedSerializer, _trusted.value, "trusted.json")
        _peers.update { peers ->
            val peer = peers[id] ?: return@update peers
            val updated = peer.copy(endpoints = peer.endpoints - DiscoverySource.Trusted)
            if (updated.isOnline) peers + (id to updated) else peers - id
        }
        updateSettings { s -> s.copy(syncRules = s.syncRules.filter { it.deviceId != id }) }
        publishPeers()
    }

    private suspend fun deliverPendingUnpairs() {
        if (!deliveringUnpairs.compareAndSet(false, true)) return
        try {
            val pending = store.load(trustedSerializer, "pending-unpairs.json").orEmpty().toMutableMap()
            for ((id, device) in pending.toMap()) {
                val endpoints = peer(id)?.orderedEndpoints.orEmpty().toMutableList()
                if (device.lastHost != null && device.lastPort != null) endpoints += Endpoint(device.lastHost, device.lastPort)
                if (endpoints.isEmpty()) continue
                try {
                    connect(endpoints, device.fingerprint).first.use { channel ->
                        io { channel.send(ControlMessage("unpair")) }
                        runCatching { io { channel.receiveControl() } }
                    }
                    pending -= id
                } catch (e: AirBridgeException) { /* not reachable yet */ }
            }
            store.save(trustedSerializer, pending, "pending-unpairs.json")
        } finally {
            deliveringUnpairs.set(false)
        }
    }

    private fun peerRevokedTrust(hello: Hello) {
        val device = trustedFor(hello) ?: return
        removeTrust(hello.id)
        onUnpairedByPeer?.invoke(device.name)
    }

    private fun trust(hello: Hello, address: Endpoint?) {
        val old = _trusted.value[hello.id]
        var device = (old ?: TrustedDevice(hello.id, hello.name, hello.fingerprint, hello.platform))
            .copy(name = hello.name, fingerprint = hello.fingerprint, platform = hello.platform)
        if (address != null) device = device.copy(lastHost = address.host, lastPort = address.port)
        updateTrusted(device)
    }

    /** Remember where a trusted device answered from, so it is reachable without discovery next time. */
    private fun rememberAddress(hello: Hello, wire: Wire) {
        val device = trustedFor(hello) ?: return
        val host = wire.remoteHost ?: return
        if (hello.port == 0 || (device.lastHost == host && device.lastPort == hello.port)) return
        updateTrusted(device.copy(lastHost = host, lastPort = hello.port))
    }

    // MARK: prompts

    private suspend fun ask(request: PromptRequest): Boolean {
        val decision = CompletableDeferred<Boolean>()
        decisions[request.id] = decision
        _prompts.update { it + request }
        onPrompt?.invoke(request)
        return try {
            withTimeoutOrNull(120_000) { decision.await() } ?: false
        } finally {
            decisions.remove(request.id)
            _prompts.update { list -> list.filter { it.id != request.id } }
        }
    }

    fun prompt(id: String) = _prompts.value.firstOrNull { it.id == id }

    fun respond(id: String, accept: Boolean) { decisions[id]?.complete(accept) }

    // MARK: inbox and transfers

    fun deleteText(id: String) = _inbox.update { list -> list.filter { it.id != id } }
    fun clearInbox() { _inbox.value = emptyList() }

    fun clearFinishedTransfers() {
        _transfers.update { list -> list.filter { !it.isFinished } }
    }

    /** Mutable progress for a running transfer; the list holds immutable snapshots. */
    private class Live(var transfer: Transfer) {
        var counter: (() -> Long)? = null
        var lastAt = 0L
        var lastBytes = 0L
    }

    private fun addTransfer(t: Transfer): Live {
        val l = Live(t)
        live[t.id] = l
        _transfers.update { listOf(t) + it }
        return l
    }

    private fun publish(l: Live, change: (Transfer) -> Transfer) {
        l.transfer = change(l.transfer)
        val snapshot = l.transfer
        _transfers.update { list -> list.map { if (it.id == snapshot.id) snapshot else it } }
    }

    private fun activate(l: Live, counter: () -> Long) {
        l.counter = counter
        publish(l) { it.copy(state = TransferState.Active, startedAt = System.currentTimeMillis()) }
    }

    private fun sampleProgress() {
        val now = System.currentTimeMillis()
        for (l in live.values) {
            val counter = l.counter ?: continue
            val bytes = counter()
            var rate = l.transfer.bytesPerSecond
            if (l.lastAt == 0L) { l.lastAt = now; l.lastBytes = bytes }
            else if (now - l.lastAt > 200) {
                val instant = (bytes - l.lastBytes) * 1000.0 / (now - l.lastAt)
                rate = if (rate == 0.0) instant else rate * 0.6 + instant * 0.4
                l.lastAt = now; l.lastBytes = bytes
            }
            if (bytes != l.transfer.bytes || rate != l.transfer.bytesPerSecond) publish(l) { it.copy(bytes = bytes, bytesPerSecond = rate) }
        }
    }

    private fun finish(l: Live, state: TransferState, error: String? = null, saved: List<String> = emptyList()) {
        val bytes = if (state == TransferState.Done) l.transfer.total else l.counter?.invoke() ?: l.transfer.bytes
        l.counter = null
        live.remove(l.transfer.id)
        publish(l) { it.copy(state = state, error = error, bytes = bytes, savedPaths = saved, finishedAt = System.currentTimeMillis()) }
        onTransferFinished?.invoke(l.transfer)
    }

    private fun failureState(e: Throwable) =
        if (e is AirBridgeException && e.kind == AirBridgeError.Declined) TransferState.Declined else TransferState.Failed

    // MARK: connecting

    private suspend fun <T> io(block: () -> T): T = runInterruptible(Dispatchers.IO) { block() }

    internal suspend fun connect(endpoints: List<Endpoint>, fingerprint: String?): Pair<SecureChannel, Endpoint> {
        var last: Exception = AirBridgeException(AirBridgeError.ConnectFailed, "device is not reachable")
        for (endpoint in endpoints) {
            try {
                return io {
                    val wire = TcpWire.connect(endpoint.host, endpoint.port)
                    val channel = try { SecureChannel.handshake(wire, local, isClient = true) } catch (e: Exception) { wire.close(); throw e }
                    if (fingerprint != null && channel.peer.fingerprint != fingerprint) {
                        channel.close()
                        throw AirBridgeException(AirBridgeError.AuthenticationFailed)
                    }
                    channel to endpoint
                }
            } catch (e: AirBridgeException) {
                if (e.kind == AirBridgeError.AuthenticationFailed) throw e
                last = e
            }
        }
        throw last
    }

    private suspend fun connect(peer: Peer): Pair<SecureChannel, Endpoint> {
        val fingerprint = peer.fingerprint ?: _trusted.value[peer.id]?.fingerprint
        val result = connect(peer.orderedEndpoints, fingerprint)
        rememberAddress(result.first.peer, result.first.wire)
        return result
    }

    // MARK: outgoing operations

    suspend fun send(files: List<File>, peer: Peer, sync: Boolean = false): Transfer = send(OutgoingItems.expand(files), peer, sync)

    /** Sends files and folders (push). [sync] marks auto-upload transfers that overwrite. */
    suspend fun send(outgoing: OutgoingItems, peer: Peer, sync: Boolean = false): Transfer {
        val transferId = UUID.randomUUID().toString().uppercase()
        val record = addTransfer(Transfer(transferId, TransferDirection.Outgoing, peer.name, outgoing.title, outgoing.total, sync))
        try {
            val (control, endpoint) = connect(peer)
            control.use { push(outgoing, transferId, sync, it, endpoint, record) }
        } catch (e: Exception) {
            finish(record, failureState(e), e.message)
            throw e
        }
        finish(record, TransferState.Done)
        return record.transfer
    }

    /** Client-side push once the control channel is up. [endpoint] null means relay. */
    private suspend fun push(outgoing: OutgoingItems, transferId: String, sync: Boolean, control: SecureChannel, endpoint: Endpoint?, record: Live) {
        io { control.send(ControlMessage("offer", transferId = transferId, items = outgoing.items, total = outgoing.total, sync = if (sync) true else null)) }
        publish(record) { it.copy(state = TransferState.WaitingForAcceptance) }
        val reply = io { control.receiveControl() }
        if (reply.t == "notPaired") {
            peerRevokedTrust(control.peer)
            throw AirBridgeException(AirBridgeError.NotTrusted)
        }
        if (reply.t != "accept") throw AirBridgeException(AirBridgeError.Declined, reply.reason ?: "")

        ChunkSource(outgoing).use { source ->
            activate(record) { source.sent }
            val streams = reply.streams ?: 0
            if (endpoint != null && streams > 0) {
                runClientTransfer(control, endpoint, transferId, minOf(streams, 16), Role.Send(source))
            } else {
                io { runStream(control, Role.Send(source)) }
                val done = io { control.receiveControl() }
                if (done.t != "complete") throw AirBridgeException(AirBridgeError.ProtocolViolation, done.reason ?: "transfer failed")
            }
        }
    }

    suspend fun sendText(text: String, peer: Peer) {
        connect(peer).first.use { control ->
            io { control.send(ControlMessage("text", text = text)) }
            val reply = io { control.receiveControl() }
            if (reply.t != "ok") throw AirBridgeException(AirBridgeError.Declined, reply.reason ?: "")
        }
    }

    /** Pairs with a device. [showCode] gets the 6-digit code to compare. */
    suspend fun pair(peer: Peer, showCode: (String) -> Unit) {
        val (control, endpoint) = connect(peer.orderedEndpoints, peer.fingerprint)
        control.use {
            showCode(it.sas)
            io { it.send(ControlMessage("pair")) }
            val reply = io { it.receiveControl() }
            if (reply.t != "pairAccepted") throw AirBridgeException(AirBridgeError.Declined, reply.reason ?: "")
            trust(it.peer, endpoint)
            rememberAddress(it.peer, it.wire)
        }
    }

    suspend fun browse(peer: Peer, path: String = ""): List<RemoteEntry> {
        connect(peer).first.use { control ->
            io { control.send(ControlMessage("list", path = path)) }
            val reply = io { control.receiveControl() }
            if (reply.t == "notPaired") { peerRevokedTrust(control.peer); throw AirBridgeException(AirBridgeError.NotTrusted) }
            if (reply.t != "listing") throw AirBridgeException(AirBridgeError.Declined, reply.reason ?: "")
            return reply.entries.orEmpty()
        }
    }

    /** Downloads paths from a trusted device's shared folder. */
    suspend fun pull(paths: List<String>, peer: Peer): Transfer {
        val (control, endpoint) = connect(peer)
        control.use {
            io { it.send(ControlMessage("pull", paths = paths)) }
            val offer = io { it.receiveControl() }
            if (offer.t == "notPaired") { peerRevokedTrust(it.peer); throw AirBridgeException(AirBridgeError.NotTrusted) }
            if (offer.t != "offer") throw AirBridgeException(AirBridgeError.Declined, offer.reason ?: "")
            return receiveOffer(offer, it, requested = true, clientEndpoint = endpoint)
        }
    }

    // MARK: internet links (relay)

    val relayConfigured get() = runCatching { URI(settings.value.relayUrl).host?.isNotEmpty() == true }.getOrDefault(false)

    /** Shares files through a one-time internet link; returns once the recipient has received them. */
    suspend fun shareViaLink(outgoing: OutgoingItems, onLink: (String) -> Unit): Transfer {
        val base = runCatching { URI(settings.value.relayUrl) }.getOrNull()?.takeIf { !it.host.isNullOrEmpty() }
            ?: throw AirBridgeException(AirBridgeError.ConnectFailed, "Set a relay URL in Settings first")
        val room = Base64.getUrlEncoder().withoutPadding().encodeToString(P256.randomBytes(16))
        // The fingerprint travels in the fragment, which browsers never send to the relay.
        onLink("${base.scheme}://${base.authority}/r/$room#${identity.fingerprint}")

        val transferId = UUID.randomUUID().toString().uppercase()
        val record = addTransfer(Transfer(transferId, TransferDirection.Outgoing, "Link recipient", outgoing.title, outgoing.total,
            state = TransferState.WaitingForAcceptance))
        try {
            val control = io {
                val wire = RelayWire.connect(relaySocketUrl(base, room, "host"), 3_600_000)
                SecureChannel.handshake(wire, local, isClient = true)
            }
            control.use { push(outgoing, transferId, false, it, null, record) }
        } catch (e: Exception) {
            finish(record, failureState(e), e.message)
            throw e
        }
        finish(record, TransferState.Done)
        return record.transfer
    }

    /** Opens a link someone shared: connects through the relay and receives their files. */
    suspend fun openLink(link: String) {
        val (base, room, fingerprint) = parseLink(link) ?: throw AirBridgeException(AirBridgeError.ProtocolViolation, "Not an AirBridge link")
        val control = io {
            val wire = RelayWire.connect(relaySocketUrl(base, room, "join"), 30_000)
            SecureChannel.handshake(wire, local, isClient = false)
        }
        control.use {
            if (fingerprint != null && !it.peer.fingerprint.equals(fingerprint, ignoreCase = true))
                throw AirBridgeException(AirBridgeError.AuthenticationFailed)
            val offer = io { it.receiveControl() }
            if (offer.t != "offer") throw AirBridgeException(AirBridgeError.ProtocolViolation, "expected an offer")
            receiveOffer(offer, it, requested = false, clientEndpoint = null)
        }
    }

    // MARK: transfer plumbing

    private sealed interface Role {
        class Send(val source: ChunkSource) : Role
        class Receive(val sink: ChunkSink) : Role
    }

    private class ActiveTransfer(val fingerprint: String, val role: Role)

    /** Client side of the data phase: open the stream connections and run them. */
    private suspend fun runClientTransfer(control: SecureChannel, endpoint: Endpoint, transferId: String, streams: Int, role: Role) {
        val fingerprint = control.peer.fingerprint
        val opened = ConcurrentHashMap.newKeySet<SecureChannel>()
        try {
            coroutineScope {
                val confirmation = if (role is Role.Send) async { io { control.receiveControl() } } else null
                val tasks = List(streams) {
                    async {
                        val (channel, _) = connect(listOf(endpoint), fingerprint)
                        opened += channel
                        io {
                            channel.send(ControlMessage("stream", transferId = transferId))
                            runStream(channel, role)
                        }
                    }
                }
                when (role) {
                    is Role.Send -> {
                        // Streams finish pumping; the receiver confirms on the control connection.
                        try { tasks.awaitAll() } catch (e: Exception) { control.close(); throw e }
                        val done = confirmation!!.await()
                        if (done.t != "complete") throw AirBridgeException(AirBridgeError.ProtocolViolation, done.reason ?: "transfer failed")
                    }
                    is Role.Receive -> {
                        tasks.forEach { t -> launch { runCatching { t.await() }.onFailure { role.sink.fail(it) } } }
                        role.sink.await()
                        role.sink.commit()
                        io { control.send(ControlMessage("complete", transferId = transferId)) }
                    }
                }
            }
        } finally {
            opened.forEach { it.close() }
        }
    }

    /** Runs one bound stream in either direction until the transfer's data is exhausted. Blocking. */
    private fun runStream(channel: SecureChannel, role: Role) {
        when (role) {
            is Role.Send -> {
                val source = role.source
                while (true) {
                    val chunk = source.next() ?: break
                    channel.sendPlaintext(source.plaintext(chunk))
                    source.addProgress(chunk.length.toLong())
                }
            }
            is Role.Receive -> {
                val sink = role.sink
                while (!sink.isComplete) {
                    val frame = channel.receive()
                    if (frame.type == FrameType.CHUNK) sink.write(frame.data, frame.offset)
                }
            }
        }
    }

    // MARK: incoming

    private suspend fun handleIncoming(wire: Wire) {
        try {
            val channel = io { SecureChannel.handshake(wire, local, isClient = false) }
            channel.use {
                val first = io { it.receiveControl() }
                when (first.t) {
                    "stream" -> attachStream(it, first)
                    "offer" -> receiveOffer(first, it, requested = false, clientEndpoint = null)
                    "text" -> handleText(first, it)
                    "pair" -> handlePair(it)
                    "list" -> handleList(first, it)
                    "pull" -> handlePull(first, it)
                    "unpair" -> { peerRevokedTrust(it.peer); io { it.send(ControlMessage("ok")) } }
                    else -> io { it.send(ControlMessage.error("unknown request ${first.t}")) }
                }
            }
        } catch (e: Exception) {
            wire.close()
        }
    }

    private suspend fun attachStream(channel: SecureChannel, msg: ControlMessage) {
        val transfer = msg.transferId?.let { active[it] }
        if (transfer == null || transfer.fingerprint != channel.peer.fingerprint)
            throw AirBridgeException(AirBridgeError.ProtocolViolation, "unknown transfer")
        try {
            io { runStream(channel, transfer.role) }
            if (transfer.role is Role.Send) {
                // Keep the socket open until the client hangs up so buffered bytes are not cut off.
                runCatching { io { channel.receive() } }
            }
        } catch (e: Exception) {
            if (transfer.role is Role.Receive) transfer.role.sink.fail(e)
            throw e
        }
    }

    /** Receiver side of an offer, pushed to us (server) or answering our pull (client). */
    private suspend fun receiveOffer(offer: ControlMessage, control: SecureChannel, requested: Boolean, clientEndpoint: Endpoint?): Transfer {
        val hello = control.peer
        val transferId = offer.transferId ?: throw AirBridgeException(AirBridgeError.ProtocolViolation, "malformed offer")
        val items = offer.items ?: throw AirBridgeException(AirBridgeError.ProtocolViolation, "malformed offer")
        val total = items.filter { !it.isDirectory }.sumOf { it.size }
        val device = trustedFor(hello)
        val sync = offer.sync == true && device != null
        if (device != null) rememberAddress(hello, control.wire)
        // An auto-upload from a device we no longer trust: tell it, so it stops syncing and drops the pairing.
        if (offer.sync == true && device == null) {
            io { control.send(ControlMessage.notPaired) }
            throw AirBridgeException(AirBridgeError.NotTrusted)
        }

        val policy = settings.value.receivePolicy
        var reason = ""
        val decision = when {
            requested -> true
            policy == ReceivePolicy.Off -> { reason = "Receiving is turned off"; false }
            device != null && (device.autoAccept || sync) -> true
            policy == ReceivePolicy.TrustedOnly && device == null -> { reason = "Only trusted devices may send"; false }
            else -> ask(PromptRequest(hello.name, hello.platform, hello.fingerprint, PromptKind.Offer, items, total))
        }
        if (!decision) {
            io { control.send(ControlMessage("decline", transferId = transferId, reason = reason.ifEmpty { "The recipient declined" })) }
            throw AirBridgeException(AirBridgeError.Declined, reason)
        }

        val baseDir = if (sync) File(downloadFolder, safeFolderName(hello.name)) else downloadFolder
        val record = addTransfer(Transfer(transferId, TransferDirection.Incoming, hello.name, titleOf(items), total, sync))
        val saved: List<String>
        try {
            ChunkSink(items, baseDir, overwrite = sync).use { sink ->
                activate(record) { sink.received }
                // Over the relay every byte already shares one pipe; use the control socket for data.
                val streams = if (control.wire.isRelay) 0 else if (total < 8L shl 20) 1 else maxOf(1, settings.value.parallelStreams)
                val accept = ControlMessage("accept", transferId = transferId, streams = streams)
                try {
                    when {
                        streams == 0 -> {
                            io { control.send(accept); runStream(control, Role.Receive(sink)) }
                            sink.commit()
                            io { control.send(ControlMessage("complete", transferId = transferId)) }
                        }
                        clientEndpoint != null -> {
                            io { control.send(accept) }
                            runClientTransfer(control, clientEndpoint, transferId, streams, Role.Receive(sink))
                        }
                        else -> {
                            active[transferId] = ActiveTransfer(hello.fingerprint, Role.Receive(sink))
                            try {
                                io { control.send(accept) }
                                coroutineScope {
                                    // If the sender disappears, the control socket closes; fail instead of waiting forever.
                                    val watcher = launch {
                                        runCatching { io { control.receive() } }
                                        sink.fail(AirBridgeException(AirBridgeError.ConnectionClosed))
                                    }
                                    sink.await()
                                    sink.commit()
                                    io { control.send(ControlMessage("complete", transferId = transferId)) }
                                    watcher.cancel()
                                }
                            } finally {
                                active.remove(transferId)
                            }
                        }
                    }
                } catch (e: Exception) {
                    sink.discard()
                    throw e
                }
                saved = sink.finalPaths.map { it.path }
            }
        } catch (e: Exception) {
            finish(record, failureState(e), e.message)
            throw e
        }
        finish(record, TransferState.Done, saved = saved)
        return record.transfer
    }

    private suspend fun handleText(msg: ControlMessage, control: SecureChannel) {
        val device = trustedFor(control.peer)
        val policy = settings.value.receivePolicy
        val text = msg.text
        if (policy == ReceivePolicy.Off || (device == null && policy != ReceivePolicy.Everyone) || text == null || text.length > 1 shl 20) {
            io { control.send(ControlMessage.error("Not accepted")) }
            return
        }
        val item = ReceivedText(control.peer.name, text)
        _inbox.update { listOf(item) + it }
        onTextReceived?.invoke(item, device?.autoClipboard == true)
        io { control.send(ControlMessage("ok")) }
    }

    private suspend fun handlePair(control: SecureChannel) {
        val hello = control.peer
        if (settings.value.receivePolicy == ReceivePolicy.Off) {
            io { control.send(ControlMessage("pairDeclined", reason = "Receiving is turned off")) }
            return
        }
        if (ask(PromptRequest(hello.name, hello.platform, hello.fingerprint, PromptKind.Pairing, code = control.sas))) {
            trust(hello, null)
            rememberAddress(hello, control.wire)
            io { control.send(ControlMessage("pairAccepted")) }
        } else {
            io { control.send(ControlMessage("pairDeclined", reason = "Pairing was declined")) }
        }
    }

    /** Resolves a path inside the shared folder, refusing anything that escapes it. */
    private fun sharedPath(relative: String): File? {
        val root = settings.value.sharedFolder?.let { File(it).canonicalFile } ?: return null
        val parts = relative.split('/').filter { it.isNotEmpty() }
        if (".." in parts) return null
        val full = parts.fold(root) { dir, p -> File(dir, p) }.canonicalFile
        return full.takeIf { it == root || it.path.startsWith(root.path + File.separator) }
    }

    private suspend fun handleList(msg: ControlMessage, control: SecureChannel) {
        if (trustedFor(control.peer)?.allowBrowse != true) { io { control.send(ControlMessage.notPaired) }; return }
        val dir = sharedPath(msg.path ?: "")?.takeIf { it.isDirectory }
        if (dir == null) { io { control.send(ControlMessage.error("No shared folder")) }; return }
        val entries = dir.listFiles().orEmpty().filter { !it.isHidden }
            .map { RemoteEntry(it.name, if (it.isFile) it.length() else 0, it.isDirectory) }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER, RemoteEntry::name))
        io { control.send(ControlMessage("listing", entries = entries)) }
    }

    private suspend fun handlePull(msg: ControlMessage, control: SecureChannel) {
        val hello = control.peer
        if (trustedFor(hello)?.allowBrowse != true) { io { control.send(ControlMessage.notPaired) }; return }
        val files = msg.paths.orEmpty().mapNotNull(::sharedPath).filter { it.exists() }
        if (files.isEmpty()) { io { control.send(ControlMessage.error("Nothing to send")) }; return }
        val outgoing = OutgoingItems.expand(files)
        val transferId = UUID.randomUUID().toString().uppercase()
        val record = addTransfer(Transfer(transferId, TransferDirection.Outgoing, hello.name, outgoing.title, outgoing.total))
        ChunkSource(outgoing).use { source ->
            active[transferId] = ActiveTransfer(hello.fingerprint, Role.Send(source))
            try {
                io { control.send(ControlMessage("offer", transferId = transferId, items = outgoing.items, total = outgoing.total)) }
                val reply = io { control.receiveControl() }
                if (reply.t != "accept") throw AirBridgeException(AirBridgeError.Declined, reply.reason ?: "")
                activate(record) { source.sent }
                val done = io { control.receiveControl() }
                if (done.t != "complete") throw AirBridgeException(AirBridgeError.ProtocolViolation, "transfer failed")
                finish(record, TransferState.Done)
            } catch (e: AirBridgeException) {
                finish(record, failureState(e), e.message)
            } finally {
                active.remove(transferId)
            }
        }
    }

    // MARK: auto-sync (auto upload)

    fun addSyncRule(folder: String, deviceId: String) = updateSettings { it.copy(syncRules = it.syncRules + SyncRule(deviceId, folder)) }

    fun removeSyncRule(id: String) {
        updateSettings { s -> s.copy(syncRules = s.syncRules.filter { it.id != id }) }
        store.remove("sync-$id.json")
    }

    private fun runSyncRules() {
        val manifestSerializer = MapSerializer(String.serializer(), String.serializer())
        for (rule in settings.value.syncRules.filter { it.enabled }) {
            val peer = peer(rule.deviceId)?.takeIf { isTrusted(it) } ?: continue
            if (!syncBusy.add(rule.id)) continue
            scope.launch {
                try {
                    val name = "sync-${rule.id}.json"
                    val (changes, manifest) = scanChanges(File(rule.folder), store.load(manifestSerializer, name).orEmpty())
                    if (changes.items.isEmpty()) return@launch
                    send(changes, peer, sync = true)
                    store.save(manifestSerializer, manifest, name)
                } catch (e: Exception) { /* retry on the next scan */ } finally {
                    syncBusy.remove(rule.id)
                }
            }
        }
    }

    companion object {
        fun relaySocketUrl(base: URI, room: String, role: String): String {
            val scheme = if (base.scheme == "http") "ws" else "wss"
            return "$scheme://${base.authority}/room/$room?role=$role"
        }

        /** Accepts https://relay/r/<room>#<fingerprint> or airbridge://join/<room>?relay=<host>#<fingerprint>. */
        fun parseLink(link: String): Triple<URI, String, String?>? {
            val uri = runCatching { URI(link.trim()) }.getOrNull() ?: return null
            val parts = uri.path.orEmpty().split('/').filter { it.isNotEmpty() }
            val fingerprint = uri.fragment?.takeIf { it.isNotEmpty() }
            if (uri.scheme == "airbridge" && uri.host == "join" && parts.isNotEmpty()) {
                val relay = uri.rawQuery.orEmpty().split('&').map { it.split('=', limit = 2) }
                    .firstOrNull { it[0] == "relay" && it.size == 2 }?.let { URLDecoder.decode(it[1], "UTF-8") } ?: return null
                return Triple(URI(if ("://" in relay) relay else "https://$relay"), parts[0], fingerprint)
            }
            if ((uri.scheme == "https" || uri.scheme == "http") && parts.size == 2 && parts[0] == "r")
                return Triple(URI("${uri.scheme}://${uri.authority}"), parts[1], fingerprint)
            return null
        }

        fun safeFolderName(name: String): String {
            val cleaned = name.map { if (it in "/\\:*?\"<>|" || it < ' ') '-' else it }.joinToString("").trim()
            return if (cleaned.isEmpty() || cleaned.startsWith(".")) "Device" else cleaned
        }

        /** Files whose size or modification time changed since the last successful sync. */
        internal fun scanChanges(folder: File, previous: Map<String, String>): Pair<OutgoingItems, Map<String, String>> {
            val all = OutgoingItems.expand(listOf(folder))
            val manifest = mutableMapOf<String, String>()
            val changed = OutgoingItems()
            all.items.forEachIndexed { i, item ->
                if (item.isDirectory) return@forEachIndexed
                val file = File(all.paths[i]!!)
                val signature = "${item.size}:${file.lastModified() / 1000}"
                manifest[item.path] = signature
                if (previous[item.path] != signature) changed.addFile(item.path, item.size, file.path, all.sources[i]!!)
            }
            return changed to manifest
        }
    }
}
