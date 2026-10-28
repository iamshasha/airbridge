package app.airbridge.core

import java.io.File
import java.nio.file.Files
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Runs the Swift reference implementation (`airbridge-cli`, built with `swift build -c release`)
 * as a real peer, so these tests prove wire compatibility with the Mac, iPhone and Windows apps.
 */
class SwiftPeer private constructor(private val process: Process, val home: File) : AutoCloseable {
    val downloads = File(home, "Downloads")
    val shared = File(home, "Shared")
    var port = 0; private set
    var fingerprint = ""; private set
    private val lines = LinkedBlockingQueue<String>()
    val output = mutableListOf<String>()

    companion object {
        val repoRoot = File(System.getProperty("airbridge.repoRoot") ?: "../..").absoluteFile
        val cli = File(repoRoot, ".build/release/airbridge-cli")
        val available get() = cli.canExecute()

        private fun builder(home: File, vararg args: String) = ProcessBuilder(cli.path, *args).apply {
            environment()["AIRBRIDGE_HOME"] = File(home, "state").path
            environment()["AIRBRIDGE_PORT"] = "0"
            environment()["AIRBRIDGE_DOWNLOADS"] = File(home, "Downloads").path
            environment()["AIRBRIDGE_SHARED"] = File(home, "Shared").path
            environment()["AIRBRIDGE_NAME"] = "Swift Mac"
            redirectErrorStream(true)
        }

        /** Starts `airbridge-cli receive`, which auto-accepts offers and pairing. */
        fun startReceiver(): SwiftPeer {
            val home = Files.createTempDirectory("ab-swift-").toFile()
            File(home, "Shared").mkdirs()
            val peer = SwiftPeer(builder(home, "receive").start(), home)
            thread(isDaemon = true) {
                peer.process.inputStream.bufferedReader().forEachLine { synchronized(peer.output) { peer.output += it }; peer.lines.put(it) }
            }
            peer.port = peer.waitForLine { it.startsWith("Listening on port ") }.split(' ')[3].trimEnd(';').toInt()
            peer.fingerprint = peer.waitForLine { it.startsWith("FINGERPRINT ") }.split(' ')[1]
            return peer
        }

        /** Runs a one-shot CLI command (send/text/share/open) and returns its exit code and output. */
        fun run(home: File, vararg args: String): Pair<Int, String> {
            val process = builder(home, *args).start()
            val out = StringBuilder()
            val reader = thread { out.append(process.inputStream.bufferedReader().readText()) }
            val finished = process.waitFor(40, TimeUnit.SECONDS)
            if (!finished) process.destroyForcibly().waitFor()
            reader.join()
            return (if (finished) process.exitValue() else -1) to out.toString()
        }
    }

    fun waitForLine(seconds: Long = 30, match: (String) -> Boolean): String {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
        while (true) {
            val line = lines.poll(deadline - System.nanoTime(), TimeUnit.NANOSECONDS)
                ?: error("Swift peer never printed the expected line. Output so far:\n${synchronized(output) { output.joinToString("\n") }}")
            if (match(line)) return line
        }
    }

    override fun close() {
        process.destroyForcibly().waitFor()
        home.deleteRecursively()
    }
}
