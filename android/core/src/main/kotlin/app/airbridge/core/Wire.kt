package app.airbridge.core

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Byte stream carrying length-prefixed frames: direct TCP, or a WebSocket to the internet relay.
 * Calls block; the engine runs them on [kotlinx.coroutines.Dispatchers.IO] and cancels by closing.
 */
abstract class Wire : AutoCloseable {
    abstract val isRelay: Boolean
    /** Address the peer connected from (TCP only), used to remember trusted devices. */
    open val remoteHost: String? get() = null

    abstract fun readExactly(buffer: ByteArray, offset: Int = 0, length: Int = buffer.size - offset)
    /** Writes in call order. Callers serialize writes per wire. */
    abstract fun write(data: ByteArray)

    fun receiveFrame(): ByteArray {
        val header = ByteArray(4)
        readExactly(header)
        val length = header.u32(0)
        if (length < 0 || length > MAX_FRAME) throw AirBridgeException(AirBridgeError.ProtocolViolation, "frame too large")
        return ByteArray(length.toInt()).also { readExactly(it) }
    }

    fun sendFrame(payload: ByteArray) {
        val frame = ByteArray(4 + payload.size)
        frame.putU32(0, payload.size.toLong())
        payload.copyInto(frame, 4)
        write(frame)
    }

    companion object {
        const val MAX_FRAME = 16L shl 20
    }
}

class TcpWire(private val socket: Socket) : Wire() {
    private val input: InputStream
    private val output: OutputStream

    init {
        socket.tcpNoDelay = true
        socket.keepAlive = true
        runCatching { socket.sendBufferSize = 4 shl 20; socket.receiveBufferSize = 4 shl 20 }
        input = socket.getInputStream()
        output = socket.getOutputStream()
    }

    override val isRelay get() = false

    override val remoteHost: String?
        get() {
            val address = (socket.remoteSocketAddress as? InetSocketAddress)?.address ?: return null
            if (address is Inet6Address && address.isLinkLocalAddress) return null
            return address.hostAddress
        }

    override fun readExactly(buffer: ByteArray, offset: Int, length: Int) {
        var done = 0
        try {
            while (done < length) {
                val n = input.read(buffer, offset + done, length - done)
                if (n < 0) throw EOFException()
                done += n
            }
        } catch (e: EOFException) {
            throw AirBridgeException(AirBridgeError.ConnectionClosed)
        } catch (e: IOException) {
            throw AirBridgeException(AirBridgeError.ConnectFailed, e.message)
        }
    }

    override fun write(data: ByteArray) {
        try { output.write(data) } catch (e: IOException) { throw AirBridgeException(AirBridgeError.ConnectFailed, e.message) }
    }

    override fun close() { runCatching { socket.close() } }

    companion object {
        fun connect(host: String, port: Int, timeoutMillis: Int = 6000): TcpWire {
            val socket = Socket()
            try {
                socket.connect(InetSocketAddress(host, port), timeoutMillis)
                return TcpWire(socket)
            } catch (e: SocketTimeoutException) {
                socket.close()
                throw AirBridgeException(AirBridgeError.Timeout)
            } catch (e: IOException) {
                socket.close()
                throw AirBridgeException(AirBridgeError.ConnectFailed, e.message)
            }
        }
    }
}

/**
 * WebSocket to the relay (relay/src/index.js). The relay pairs two sockets and says "ready";
 * after that it is a plain byte stream split into messages of at most 256 KiB.
 */
class RelayWire private constructor(private val queue: LinkedBlockingQueue<Any>) : Wire() {
    private lateinit var socket: WebSocket
    private var current: ByteString? = null
    private var position = 0

    override val isRelay get() = true

    override fun readExactly(buffer: ByteArray, offset: Int, length: Int) {
        var filled = 0
        while (filled < length) {
            val chunk = current?.takeIf { position < it.size } ?: run {
                when (val next = queue.take()) {
                    is ByteString -> { current = next; position = 0; next }
                    else -> throw AirBridgeException(AirBridgeError.ConnectionClosed)
                }
            }
            val n = minOf(length - filled, chunk.size - position)
            chunk.copyInto(position, buffer, offset + filled, n)
            position += n
            filled += n
        }
    }

    override fun write(data: ByteArray) {
        var offset = 0
        while (offset < data.size) {
            // OkHttp buffers sends without limit until 16 MiB, then fails: keep the queue short.
            while (socket.queueSize() > 4L shl 20) Thread.sleep(5)
            val n = minOf(MESSAGE_SIZE, data.size - offset)
            if (!socket.send(data.toByteString(offset, n))) throw AirBridgeException(AirBridgeError.ConnectionClosed)
            offset += n
        }
    }

    override fun close() {
        if (::socket.isInitialized) socket.cancel()
        queue.offer(CLOSED)
    }

    companion object {
        const val MESSAGE_SIZE = 256 shl 10
        private val CLOSED = Any()
        private val client by lazy { OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS).build() }

        fun connect(url: String, waitForPeerMillis: Long): RelayWire {
            val queue = LinkedBlockingQueue<Any>()
            val ready = LinkedBlockingQueue<Result<Unit>>()
            val wire = RelayWire(queue)
            wire.socket = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (text == "ready") ready.offer(Result.success(Unit))
                    else if (text.startsWith("error")) ready.offer(Result.failure(AirBridgeException(AirBridgeError.ConnectFailed, text)))
                }
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) { queue.offer(bytes) }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    ready.offer(Result.failure(AirBridgeException(AirBridgeError.ConnectionClosed))); queue.offer(CLOSED)
                }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    ready.offer(Result.failure(AirBridgeException(AirBridgeError.ConnectFailed, t.message))); queue.offer(CLOSED)
                }
            })
            val result = ready.poll(waitForPeerMillis, TimeUnit.MILLISECONDS)
            if (result == null) { wire.close(); throw AirBridgeException(AirBridgeError.Timeout) }
            result.onFailure { wire.close(); throw it }
            return wire
        }
    }
}

internal fun ByteArray.u32(at: Int): Long =
    ((this[at].toLong() and 0xFF) shl 24) or ((this[at + 1].toLong() and 0xFF) shl 16) or
        ((this[at + 2].toLong() and 0xFF) shl 8) or (this[at + 3].toLong() and 0xFF)

internal fun ByteArray.u64(at: Int): Long = (u32(at) shl 32) or u32(at + 4)

internal fun ByteArray.putU32(at: Int, value: Long) {
    for (i in 0 until 4) this[at + i] = (value ushr (24 - 8 * i)).toByte()
}

internal fun ByteArray.putU64(at: Int, value: Long) {
    for (i in 0 until 8) this[at + i] = (value ushr (56 - 8 * i)).toByte()
}
