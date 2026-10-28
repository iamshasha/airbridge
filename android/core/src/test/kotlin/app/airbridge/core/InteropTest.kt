package app.airbridge.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.random.Random
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Full flows between the Kotlin engine and the Swift reference implementation, in both directions. */
class InteropTest {
    private lateinit var temp: File
    private lateinit var node: Node

    @BeforeEach
    fun setUp() {
        assumeTrue(SwiftPeer.available, "Build the Swift CLI first: swift build -c release (${SwiftPeer.cli})")
        temp = Files.createTempDirectory("ab-kt-").toFile()
        node = Node(Store(File(temp, "state")), "Android Phone", defaultDownloads = File(temp, "Downloads"))
        node.updateSettings { it.copy(port = 0, sharedFolder = File(temp, "Shared").apply { mkdirs() }.path) }
        node.onPrompt = { node.respond(it.id, true) }
        node.start()
    }

    @AfterEach
    fun tearDown() {
        if (::node.isInitialized) node.close()
        if (::temp.isInitialized) temp.deleteRecursively()
    }

    private fun writeRandom(file: File, size: Int) {
        file.parentFile.mkdirs()
        file.writeBytes(Random.nextBytes(size))
    }

    private fun hash(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    private fun makeFolder(root: File): File {
        val folder = File(root, "Holiday Photos")
        writeRandom(File(folder, "big.raw"), (40 shl 20) + 12345) // > 8 MiB → parallel streams
        writeRandom(File(folder, "nested/note.txt"), 17)
        File(folder, "empty").mkdirs()
        File(folder, "zero.dat").writeBytes(ByteArray(0))
        return folder
    }

    private fun assertSameFolder(expected: File, actual: File) {
        assertEquals(hash(File(expected, "big.raw")), hash(File(actual, "big.raw")))
        assertEquals(hash(File(expected, "nested/note.txt")), hash(File(actual, "nested/note.txt")))
        assertTrue(File(actual, "empty").isDirectory)
        assertTrue(File(actual, "zero.dat").isFile)
    }

    @Test
    fun androidPairsWithMacThenSendsTextFolderBrowsesPullsAndUnpairs(): Unit = runBlocking {
        SwiftPeer.startReceiver().use { swift ->
            // Pairing: both sides must derive the same 6-digit code.
            var code: String? = null
            node.pair(Peer.at("127.0.0.1", swift.port)) { code = it }
            val swiftCode = swift.waitForLine { it.startsWith("PAIRCODE ") }.split(' ')[1]
            assertEquals(swiftCode, code)
            val mac = node.trusted.value.values.single()
            assertEquals(swift.fingerprint, mac.fingerprint)
            val peer = node.peer(mac.id)!!

            node.sendText("Hello Mac, from Android 🤖", peer)
            swift.waitForLine { it == "TEXT Android Phone: Hello Mac, from Android 🤖" }

            // Trusted → auto-accepted, parallel streams for the 40 MB file.
            val folder = makeFolder(temp)
            assertEquals(TransferState.Done, node.send(listOf(folder), peer).state)
            swift.waitForLine { it.startsWith("TRANSFER Holiday Photos done") }
            assertSameFolder(folder, File(swift.downloads, "Holiday Photos"))

            // Browse and pull from the Mac's shared folder.
            writeRandom(File(swift.shared, "report.pdf"), 3 shl 20)
            assertTrue(node.browse(peer).any { it.name == "report.pdf" && it.size == 3L shl 20 })
            assertEquals(TransferState.Done, node.pull(listOf("report.pdf"), peer).state)
            assertEquals(hash(File(swift.shared, "report.pdf")), hash(File(node.downloadFolder, "report.pdf")))

            // Unpairing tells the Mac.
            node.unpair(mac.id)
            swift.waitForLine { it == "UNPAIRED Android Phone" }
        }
    }

    @Test
    fun macSendsFolderAndTextToAndroid(): Unit = runBlocking {
        val swiftHome = Files.createTempDirectory("ab-swift-send-").toFile()
        try {
            val folder = makeFolder(swiftHome)
            val port = node.listeningPort.value!!
            var (exit, output) = SwiftPeer.run(swiftHome, "send", "127.0.0.1:$port", folder.path)
            assertEquals(0, exit, output)
            assertSameFolder(folder, File(node.downloadFolder, "Holiday Photos"))
            withTimeout(5000) { while (node.transfers.value.none { it.direction == TransferDirection.Incoming && it.isFinished }) kotlinx.coroutines.delay(20) }
            assertEquals(TransferState.Done, node.transfers.value.first { it.direction == TransferDirection.Incoming }.state)

            SwiftPeer.run(swiftHome, "text", "127.0.0.1:$port", "Hi Android 👋").let { (e, o) -> exit = e; output = o }
            assertEquals(0, exit, output)
            assertEquals("Hi Android 👋", node.inbox.value.first().text)
        } finally {
            swiftHome.deleteRecursively()
        }
    }

    @Test
    fun internetLinksWorkBothWaysThroughTheRelay(): Unit = runBlocking {
        MockRelay().use { relay ->
            val swiftHome = Files.createTempDirectory("ab-swift-link-").toFile()
            try {
                // Mac shares a link, Android opens it.
                val file = File(swiftHome, "movie.mov").also { writeRandom(it, (5 shl 20) + 777) }
                coroutineScope {
                    val share = async(kotlinx.coroutines.Dispatchers.IO) { SwiftPeer.run(swiftHome, "share", relay.baseUrl, file.path) }
                    val room = relay.waitForHostedRoom()
                    try { withTimeout(20_000) { node.openLink("${relay.baseUrl}/r/$room") } } catch (e: Throwable) { println("openLink failed: $e"); throw e }
                    val (exit, output) = share.await()
                    assertEquals(0, exit, output)
                }
                assertEquals(hash(file), hash(File(node.downloadFolder, "movie.mov")))

                // Android shares a link, the Mac opens it.
                node.updateSettings { it.copy(relayUrl = relay.baseUrl) }
                val mine = File(temp, "slides.key").also { writeRandom(it, 2 shl 20) }
                val link = CompletableDeferred<String>()
                coroutineScope {
                    val sharing = async { node.shareViaLink(OutgoingItems.expand(listOf(mine))) { link.complete(it) } }
                    val (exit, output) = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { SwiftPeer.run(swiftHome, "open", link.await()) }
                    assertEquals(0, exit, output)
                    assertEquals(TransferState.Done, sharing.await().state)
                }
                assertEquals(hash(mine), hash(File(swiftHome, "Downloads/slides.key")))
            } finally {
                swiftHome.deleteRecursively()
            }
        }
    }

    @Test
    fun linksParseAndUnsafePathsAreRefused() {
        val (base, room, fp) = Node.parseLink("https://relay.example.com/r/abc123#deadbeef")!!
        assertEquals("https://relay.example.com", base.toString()); assertEquals("abc123", room); assertEquals("deadbeef", fp)
        assertEquals("room9", Node.parseLink("airbridge://join/room9?relay=relay.example.com")!!.second)
        for (bad in listOf("../etc/passwd", "a/../../b", "/", "")) {
            assertTrue(runCatching { ChunkSink.safeComponents(bad) }.isFailure, bad)
        }
    }
}
