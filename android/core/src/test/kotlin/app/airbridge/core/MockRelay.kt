package app.airbridge.core

import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/** In-process stand-in for relay/src/index.js: pairs host and join sockets per room and pipes binary. */
class MockRelay : AutoCloseable {
    private val server = MockWebServer()
    private class Room { var host: WebSocket? = null; var join: WebSocket? = null }
    private val rooms = mutableMapOf<String, Room>()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val parts = request.url.pathSegments
                val role = request.url.queryParameter("role")
                if (parts.size != 2 || parts[0] != "room" || role == null) return MockResponse.Builder().code(404).build()
                val room = parts[1]
                return MockResponse.Builder().webSocketUpgrade(object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        val ready = synchronized(rooms) {
                            val r = rooms.getOrPut(room) { Room() }
                            if (role == "host") r.host = webSocket else r.join = webSocket
                            r.host != null && r.join != null
                        }
                        if (ready) synchronized(rooms) { rooms.getValue(room).run { host!!.send("ready"); join!!.send("ready") } }
                    }
                    override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                        check(bytes.size <= 1 shl 20) { "messages must fit Cloudflare's 1 MiB cap" }
                        other(room, webSocket)?.send(bytes)
                    }
                    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { other(room, webSocket)?.close(1000, null) }
                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { other(room, webSocket)?.cancel() }
                }).build()
            }
        }
        server.start()
    }

    private fun other(room: String, socket: WebSocket) = synchronized(rooms) {
        rooms[room]?.let { if (it.host === socket) it.join else it.host }
    }

    val baseUrl: String get() = "http://127.0.0.1:${server.port}"

    /** The room a sharer is waiting in. */
    fun waitForHostedRoom(): String {
        repeat(500) {
            synchronized(rooms) { rooms.entries.firstOrNull { it.value.host != null && it.value.join == null }?.let { return it.key } }
            Thread.sleep(20)
        }
        error("nobody connected to the relay")
    }

    override fun close() = server.close()
}
