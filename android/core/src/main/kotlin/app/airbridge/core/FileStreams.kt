package app.airbridge.core

import kotlinx.coroutines.CompletableDeferred
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.util.concurrent.atomic.AtomicLong

/** Opens a readable, seekable channel for one outgoing file (a [File], or an Android content URI). */
fun interface ChannelOpener {
    fun open(): FileChannel
}

/** User-picked files and folders expanded into protocol items, each with a way to read it. */
class OutgoingItems {
    val items = mutableListOf<FileItem>()
    val sources = mutableListOf<ChannelOpener?>()
    /** Local paths where known (files on disk); used for sync manifests. */
    val paths = mutableListOf<String?>()
    val total get() = items.filter { !it.isDirectory }.sumOf { it.size }
    val title get() = titleOf(items)

    fun addDirectory(protocolPath: String) {
        items += FileItem(items.size, protocolPath, 0, true)
        sources += null
        paths += null
    }

    fun addFile(protocolPath: String, size: Long, path: String? = null, opener: ChannelOpener) {
        items += FileItem(items.size, protocolPath, size)
        sources += opener
        paths += path
    }

    companion object {
        fun expand(roots: List<File>): OutgoingItems {
            val result = OutgoingItems()
            for (root in roots) {
                val full = root.absoluteFile
                if (full.isDirectory) {
                    result.addDirectory(full.name)
                    full.walkTopDown().filter { it != full && !it.isHidden }.sortedBy { it.path }.forEach { entry ->
                        val rel = full.name + "/" + entry.relativeTo(full).invariantSeparatorsPath
                        if (entry.isDirectory) result.addDirectory(rel)
                        else if (entry.isFile) result.addFile(rel, entry.length(), entry.path) { FileChannel.open(entry.toPath(), StandardOpenOption.READ) }
                    }
                } else {
                    result.addFile(full.name, full.length(), full.path) { FileChannel.open(full.toPath(), StandardOpenOption.READ) }
                }
            }
            return result
        }
    }
}

/** Sender side: hands chunks to however many streams are pumping (work stealing). */
class ChunkSource(private val outgoing: OutgoingItems) : AutoCloseable {
    private val channels = arrayOfNulls<FileChannel>(outgoing.items.size)
    private var file = 0
    private var offset = 0L
    private val progress = AtomicLong()

    val sent: Long get() = progress.get()
    internal fun addProgress(n: Long) = progress.addAndGet(n)

    data class Chunk(val index: Int, val offset: Long, val length: Int)

    @Synchronized
    fun next(): Chunk? {
        while (file < outgoing.items.size) {
            val item = outgoing.items[file]
            if (item.isDirectory || offset >= item.size) { file++; offset = 0; continue }
            val length = minOf(CHUNK_SIZE.toLong(), item.size - offset).toInt()
            return Chunk(file, offset, length).also { offset += length }
        }
        return null
    }

    @Synchronized
    private fun channel(index: Int): FileChannel = channels[index] ?: outgoing.sources[index]!!.open().also { channels[index] = it }

    /** Complete chunk plaintext: 0x02 || u32 index || u64 offset || bytes. */
    fun plaintext(chunk: Chunk): ByteArray {
        val buffer = ByteArray(13 + chunk.length)
        buffer[0] = FrameType.CHUNK
        buffer.putU32(1, chunk.index.toLong())
        buffer.putU64(5, chunk.offset)
        val target = ByteBuffer.wrap(buffer, 13, chunk.length)
        val channel = channel(chunk.index)
        var position = chunk.offset
        while (target.hasRemaining()) {
            val n = channel.read(target, position)
            if (n <= 0) throw AirBridgeException(AirBridgeError.ProtocolViolation, "file changed while sending")
            position += n
        }
        return buffer
    }

    @Synchronized
    override fun close() { channels.forEach { runCatching { it?.close() } } }

    companion object {
        const val CHUNK_SIZE = 1 shl 20
    }
}

/** Receiver side: preallocated part files written at arbitrary offsets from parallel streams. */
class ChunkSink(private val items: List<FileItem>, baseDirectory: File, overwrite: Boolean) : AutoCloseable {
    private val files = HashMap<Int, RandomAccessFile>()
    private val paths = HashMap<Int, Pair<File, File>>()
    private val done = CompletableDeferred<Unit>()
    private val progress = AtomicLong()

    val total: Long = items.filter { !it.isDirectory }.sumOf { it.size }
    val received: Long get() = progress.get()
    val finalPaths = mutableListOf<File>()
    val isComplete get() = done.isCompleted && !done.isCancelled

    init {
        baseDirectory.mkdirs()
        // Rename colliding top-level names once so a folder's children stay together.
        val topLevel = LinkedHashMap<String, String>()
        for (item in items) {
            val top = safeComponents(item.path)[0]
            if (top !in topLevel) topLevel[top] = if (overwrite) top else uniqueName(top, baseDirectory, topLevel.values.toSet())
        }
        for (item in items) {
            val comps = safeComponents(item.path)
            comps[0] = topLevel.getValue(comps[0])
            val target = comps.fold(baseDirectory) { dir, c -> File(dir, c) }
            if (item.isDirectory) { target.mkdirs(); continue }
            target.parentFile.mkdirs()
            val part = File(target.parentFile, ".${target.name}.abpart")
            val raf = RandomAccessFile(part, "rw")
            raf.setLength(item.size)
            files[item.i] = raf
            paths[item.i] = part to target
        }
        finalPaths += topLevel.values.sorted().map { File(baseDirectory, it) }
        if (total == 0L) done.complete(Unit)
    }

    /** Writes one decrypted chunk payload (u32 index || u64 offset || bytes) starting at [offset] in [data]. */
    fun write(data: ByteArray, offset: Int) {
        if (data.size - offset < 12) throw AirBridgeException(AirBridgeError.ProtocolViolation, "short chunk")
        val index = data.u32(offset).toInt()
        val at = data.u64(offset + 4)
        val length = data.size - offset - 12
        val raf = files[index]
        if (index !in items.indices || raf == null || at < 0 || at + length > items[index].size)
            throw AirBridgeException(AirBridgeError.ProtocolViolation, "chunk out of range")
        val buffer = ByteBuffer.wrap(data, offset + 12, length)
        var position = at
        while (buffer.hasRemaining()) position += raf.channel.write(buffer, position)
        if (progress.addAndGet(length.toLong()) >= total) done.complete(Unit)
    }

    fun fail(error: Throwable) { done.completeExceptionally(error) }

    suspend fun await() = done.await()

    /** Closes files and moves parts into place. */
    fun commit() {
        for ((i, raf) in files) {
            raf.close()
            val (part, target) = paths.getValue(i)
            target.delete()
            if (!part.renameTo(target)) throw AirBridgeException(AirBridgeError.ProtocolViolation, "could not save ${target.name}")
        }
        files.clear()
    }

    fun discard() {
        files.values.forEach { runCatching { it.close() } }
        files.clear()
        paths.values.forEach { (part, _) -> part.delete() }
    }

    override fun close() = discard()

    companion object {
        private val invalid = setOf(':', '*', '?', '"', '<', '>', '|', '\\')

        fun safeComponents(path: String): MutableList<String> {
            val comps = path.split('/', '\\').filter { it.isNotEmpty() }
            if (comps.isEmpty() || comps.any { it == "." || it == ".." || '\u0000' in it })
                throw AirBridgeException(AirBridgeError.ProtocolViolation, "unsafe path $path")
            return comps.map { c -> c.map { if (it in invalid || it < ' ') '-' else it }.joinToString("").trimEnd('.', ' ').ifEmpty { "-" } }
                .toMutableList()
        }

        private fun uniqueName(name: String, dir: File, taken: Set<String>): String {
            fun free(n: String) = n !in taken && !File(dir, n).exists()
            if (free(name)) return name
            val dot = name.lastIndexOf('.').takeIf { it > 0 }
            val stem = dot?.let { name.substring(0, it) } ?: name
            val ext = dot?.let { name.substring(it) } ?: ""
            return generateSequence(2) { it + 1 }.map { "$stem ($it)$ext" }.first(::free)
        }
    }
}
