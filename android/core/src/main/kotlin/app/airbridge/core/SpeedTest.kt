package app.airbridge.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/** How speeds are shown: megabytes per second (like file sizes) or megabits per second (like network plans). */
@Serializable
enum class SpeedUnit(val label: String) {
    @SerialName("bytes") Bytes("MB/s"),
    @SerialName("bits") Bits("Mbps");

    /** "112 MB/s" or "899 Mbps". Decimal units throughout, like Finder and internet providers. */
    fun format(bytesPerSecond: Double): String {
        var v = maxOf(0.0, if (this == Bytes) bytesPerSecond else bytesPerSecond * 8)
        val units = if (this == Bytes) listOf("B/s", "KB/s", "MB/s", "GB/s") else listOf("bps", "kbps", "Mbps", "Gbps")
        var i = 0
        while (v >= 1000 && i < units.size - 1) { v /= 1000; i++ }
        val text = when { v >= 100 || i == 0 -> "%.0f"; v >= 10 -> "%.1f"; else -> "%.2f" }.format(java.util.Locale.ROOT, v)
        return "$text ${units[i]}"
    }
}

data class SpeedTestResult(val upload: Double, val download: Double)

data class SpeedTestProgress(val phase: Phase, val fraction: Float, val bytesPerSecond: Double) {
    enum class Phase { Upload, Download }
}

/** Zero-filled chunks up to [total] bytes. Encryption makes them incompressible on the wire. */
class SpeedSource(val total: Long) {
    val sent = AtomicLong()
    private val handedOut = AtomicLong()
    private val chunk = ByteArray(13 + ChunkSource.CHUNK_SIZE).also { it[0] = FrameType.CHUNK }

    fun next(): Int? {
        while (true) {
            val done = handedOut.get()
            if (done >= total) return null
            val n = minOf(ChunkSource.CHUNK_SIZE.toLong(), total - done).toInt()
            if (handedOut.compareAndSet(done, done + n)) return n
        }
    }

    fun plaintext(length: Int): ByteArray = if (length == ChunkSource.CHUNK_SIZE) chunk else chunk.copyOf(13 + length)
}

/** Counts bytes arriving on any number of streams until [total] is reached. */
class SpeedSink(val total: Long) {
    val received = AtomicLong()
    private val done = CompletableDeferred<Unit>()
    val isComplete get() = received.get() >= total

    fun add(n: Int) { if (received.addAndGet(n.toLong()) >= total) done.complete(Unit) }
    fun fail(e: Throwable) { done.completeExceptionally(e) }
    suspend fun await() = done.await()
}

const val SPEED_TEST_LIMIT = 1L shl 30

/**
 * Measures throughput to and from [peer] over the same encrypted parallel streams files use.
 * A short probe sizes each phase to take about three seconds on this network.
 */
suspend fun Node.speedTest(peer: Peer, progress: (SpeedTestProgress) -> Unit = {}): SpeedTestResult {
    val upload = measure(peer, SpeedTestProgress.Phase.Upload, progress)
    val download = measure(peer, SpeedTestProgress.Phase.Download, progress)
    return SpeedTestResult(upload, download)
}

private suspend fun Node.measure(peer: Peer, phase: SpeedTestProgress.Phase, progress: (SpeedTestProgress) -> Unit): Double {
    val probe = speedRun(peer, phase, 8L shl 20, null)
    val total = (probe * 3).toLong().coerceIn(16L shl 20, SPEED_TEST_LIMIT)
    return speedRun(peer, phase, total) { fraction, rate -> progress(SpeedTestProgress(phase, fraction, rate)) }
}

/** One timed run. Returns bytes per second. */
private suspend fun Node.speedRun(peer: Peer, phase: SpeedTestProgress.Phase, total: Long, report: ((Float, Double) -> Unit)?): Double {
    val (control, endpoint) = connect(peer.orderedEndpoints, peer.fingerprint ?: trusted.value[peer.id]?.fingerprint)
    control.use {
        val transferId = UUID.randomUUID().toString().uppercase()
        val upload = phase == SpeedTestProgress.Phase.Upload
        io {
            control.send(ControlMessage("speedtest", transferId = transferId, total = total,
                mode = if (upload) "upload" else "download", streams = maxOf(1, settings.value.parallelStreams)))
        }
        val reply = io { control.receiveControl() }
        if (reply.t != "accept") {
            if (reply.t == "error" && reply.reason?.startsWith("unknown request") == true)
                throw AirBridgeException(AirBridgeError.ProtocolViolation, "${peer.name} needs a newer AirBridge for speed tests")
            throw AirBridgeException(AirBridgeError.Declined, reply.reason ?: "")
        }
        val streams = (reply.streams ?: 1).coerceIn(1, 16)
        val source = SpeedSource(total)
        val sink = SpeedSink(total)
        val role: Node.Role = if (upload) Node.Role.Blast(source) else Node.Role.Drain(sink)
        val counter = if (upload) source.sent else sink.received
        val start = System.nanoTime()
        fun rate(bytes: Long) = bytes / ((System.nanoTime() - start) / 1e9).coerceAtLeast(1e-3)
        val opened = ConcurrentHashMap.newKeySet<SecureChannel>()
        try {
            coroutineScope {
                val ticker = report?.let { r ->
                    launch { while (isActive) { delay(150); val b = counter.get(); r(b.toFloat() / total, rate(b)) } }
                }
                val confirmation = if (upload) async { io { control.receiveControl() } } else null
                val tasks = List(streams) {
                    async {
                        val (channel, _) = connect(listOf(endpoint), control.peer.fingerprint)
                        opened += channel
                        try {
                            io {
                                channel.send(ControlMessage("stream", transferId = transferId))
                                runStream(channel, role)
                            }
                        } catch (e: Exception) {
                            // Streams closed after all the data arrived are done, not broken.
                            if (!(!upload && sink.isComplete)) throw e
                        }
                    }
                }
                if (upload) {
                    try { tasks.awaitAll() } catch (e: Exception) { control.close(); throw e }
                    val done = confirmation!!.await()
                    if (done.t != "complete") throw AirBridgeException(AirBridgeError.ProtocolViolation, done.reason ?: "speed test failed")
                } else {
                    tasks.forEach { t -> launch { runCatching { t.await() }.onFailure { sink.fail(it) } } }
                    sink.await()
                    opened.forEach { c -> c.close() } // unblock streams still waiting for data
                    runCatching { io { control.send(ControlMessage("complete", transferId = transferId)) } }
                }
                ticker?.cancel()
            }
        } finally {
            opened.forEach { c -> c.close() }
        }
        val result = rate(total)
        report?.invoke(1f, result)
        return result
    }
}

/** Server side: count an upload, or stream a download, on the client's stream connections. */
internal suspend fun Node.handleSpeedTest(msg: ControlMessage, control: SecureChannel) {
    if (settings.value.receivePolicy == ReceivePolicy.Off) { io { control.send(ControlMessage.error("Receiving is turned off")) }; return }
    val transferId = msg.transferId
    val total = msg.total
    if (transferId == null || total == null || total <= 0 || total > SPEED_TEST_LIMIT || (msg.mode != "upload" && msg.mode != "download")) {
        io { control.send(ControlMessage.error("Bad speed test request")) }
        return
    }
    val streams = (msg.streams ?: settings.value.parallelStreams).coerceIn(1, 16)
    val sink = SpeedSink(total)
    val role = if (msg.mode == "upload") Node.Role.Drain(sink) else Node.Role.Blast(SpeedSource(total))
    active[transferId] = Node.ActiveTransfer(control.peer.fingerprint, role)
    try {
        io { control.send(ControlMessage("accept", transferId = transferId, streams = streams)) }
        if (msg.mode == "upload") {
            coroutineScope {
                // If the client disappears, its control socket closes; stop waiting.
                val watcher = launch { runCatching { io { control.receive() } }; sink.fail(AirBridgeException(AirBridgeError.ConnectionClosed)) }
                sink.await()
                io { control.send(ControlMessage("complete", transferId = transferId)) }
                control.close() // unblocks the watcher
                watcher.cancel()
            }
        } else {
            // The client says "complete" (or hangs up) when it has everything.
            runCatching { io { control.receiveControl() } }
        }
    } finally {
        active.remove(transferId)
    }
}
