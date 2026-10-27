import Foundation

let chunkSize = 1 << 20

/// Expands user-picked files/folders into protocol items with their local URLs.
struct OutgoingItems: Sendable {
    var items: [FileItem] = []
    var urls: [URL] = []
    var total: Int64 { items.reduce(0) { $0 + ($1.dir == true ? 0 : $1.size) } }

    mutating func add(path: String, url: URL, size: Int64, dir: Bool) {
        items.append(FileItem(i: items.count, path: path, size: dir ? 0 : size, dir: dir ? true : nil))
        urls.append(url)
    }

    static func expand(_ roots: [URL]) throws -> OutgoingItems {
        var out = OutgoingItems()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isRegularFileKey]
        for root in roots {
            let values = try root.resourceValues(forKeys: Set(keys))
            let base = root.lastPathComponent
            if values.isDirectory == true {
                out.add(path: base, url: root, size: 0, dir: true)
                let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
                let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                while let url = enumerator?.nextObject() as? URL {
                    let v = try url.resourceValues(forKeys: Set(keys))
                    let full = url.standardizedFileURL.resolvingSymlinksInPath().path
                    guard full.hasPrefix(rootPath) else { continue }
                    let rel = base + "/" + full.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if v.isDirectory == true {
                        out.add(path: rel, url: url, size: 0, dir: true)
                    } else if v.isRegularFile == true {
                        out.add(path: rel, url: url, size: Int64(v.fileSize ?? 0), dir: false)
                    }
                }
            } else {
                out.add(path: base, url: root, size: Int64(values.fileSize ?? 0), dir: false)
            }
        }
        return out
    }
}

/// Sender side: hands out chunks to however many streams are pumping (work stealing).
final class ChunkSource: @unchecked Sendable {
    let items: [FileItem]
    let urls: [URL]
    let progress = Locked<Int64>(0)
    private let cursor = Locked<(file: Int, offset: Int64)>((0, 0))
    private let fds = Locked<[Int: Int32]>([:])

    init(_ outgoing: OutgoingItems) {
        items = outgoing.items
        urls = outgoing.urls
    }

    func next() -> (index: Int, offset: Int64, length: Int)? {
        cursor.withLock { c in
            while c.file < items.count {
                let item = items[c.file]
                if item.dir == true || c.offset >= item.size {
                    c.file += 1; c.offset = 0
                    continue
                }
                let len = Int(min(Int64(chunkSize), item.size - c.offset))
                defer { c.offset += Int64(len) }
                return (c.file, c.offset, len)
            }
            return nil
        }
    }

    private func fd(for index: Int) throws -> Int32 {
        try fds.withLock { fds in
            if let fd = fds[index] { return fd }
            let fd = open(urls[index].path, O_RDONLY)
            guard fd >= 0 else { throw AirBridgeError.protocolViolation("cannot read \(urls[index].lastPathComponent)") }
            fcntl(fd, F_NOCACHE, 1) // stream large files without polluting the page cache
            fds[index] = fd
            return fd
        }
    }

    /// Builds a complete chunk plaintext (`0x02 || u32 index || u64 offset || bytes`), reading the file
    /// straight into the buffer so the only other copy is the encryption itself.
    func plaintext(index: Int, offset: Int64, length: Int) throws -> Data {
        let fd = try fd(for: index)
        var data = Data(count: 13 + length)
        try data.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!
            p.storeBytes(of: SecureChannel.FrameType.chunk.rawValue, as: UInt8.self)
            var idx = UInt32(index).bigEndian
            memcpy(p + 1, &idx, 4)
            var off = offset.bigEndian
            memcpy(p + 5, &off, 8)
            var done = 0
            while done < length {
                let n = pread(fd, p + 13 + done, length - done, off_t(offset) + off_t(done))
                guard n > 0 else { throw AirBridgeError.protocolViolation("file changed while sending") }
                done += n
            }
        }
        return data
    }

    func close() {
        fds.withLock { fds in fds.values.forEach { Darwin.close($0) }; fds.removeAll() }
    }
}

/// Receiver side: preallocated `.abpart` files written at arbitrary offsets from parallel streams.
final class ChunkSink: @unchecked Sendable {
    let items: [FileItem]
    let total: Int64
    let progress = Locked<Int64>(0)
    private(set) var finalURLs: [URL] = []
    private var partURLs: [Int: URL] = [:]
    private var targets: [Int: URL] = [:]
    private var fds: [Int: Int32] = [:]
    private let overwrite: Bool
    private let state = Locked<(done: Bool, error: Error?, waiters: [CheckedContinuation<Void, Error>])>((false, nil, []))

    init(items: [FileItem], baseDirectory: URL, overwrite: Bool) throws {
        self.items = items
        self.overwrite = overwrite
        total = items.reduce(0) { $0 + ($1.dir == true ? 0 : $1.size) }
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        // Rename colliding top-level names once so a folder's children stay together.
        var topLevel: [String: String] = [:]
        for item in items {
            let comps = try Self.safeComponents(item.path)
            if topLevel[comps[0]] == nil {
                topLevel[comps[0]] = overwrite ? comps[0] : Self.uniqueName(comps[0], in: baseDirectory, taken: Set(topLevel.values))
            }
        }
        for item in items {
            var comps = try Self.safeComponents(item.path)
            comps[0] = topLevel[comps[0]]!
            let target = comps.reduce(baseDirectory) { $0.appendingPathComponent($1) }
            if item.dir == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let part = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).abpart")
            let fd = open(part.path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
            guard fd >= 0 else { throw AirBridgeError.protocolViolation("cannot create \(target.lastPathComponent)") }
            if item.size > 0 { ftruncate(fd, off_t(item.size)) }
            fds[item.i] = fd
            partURLs[item.i] = part
            targets[item.i] = target
        }
        finalURLs = topLevel.values.sorted().map { baseDirectory.appendingPathComponent($0) }
        if total == 0 { state.withLock { $0.done = true } }
    }

    static func safeComponents(_ path: String) throws -> [String] {
        let comps = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !comps.isEmpty, !comps.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") }) else {
            throw AirBridgeError.protocolViolation("unsafe path \(path)")
        }
        return comps.map { $0.replacingOccurrences(of: ":", with: "-") }
    }

    static func uniqueName(_ name: String, in dir: URL, taken: Set<String>) -> String {
        let fm = FileManager.default
        func free(_ n: String) -> Bool { !taken.contains(n) && !fm.fileExists(atPath: dir.appendingPathComponent(n).path) }
        if free(name) { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for i in 2... {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if free(candidate) { return candidate }
        }
        return name
    }

    /// Writes one decrypted chunk payload.
    func write(payload: Data) throws {
        guard payload.count >= 12 else { throw AirBridgeError.protocolViolation("short chunk") }
        let index = Int(payload.readBE(UInt32.self, at: 0))
        let offset = Int64(payload.readBE(UInt64.self, at: 4))
        let length = payload.count - 12
        guard index < items.count, let fd = fds[index], offset >= 0, offset + Int64(length) <= items[index].size else {
            throw AirBridgeError.protocolViolation("chunk out of range")
        }
        try payload.withUnsafeBytes { raw in
            let p = raw.baseAddress! + 12
            var done = 0
            while done < length {
                let n = pwrite(fd, p + done, length - done, off_t(offset) + off_t(done))
                guard n > 0 else { throw AirBridgeError.protocolViolation("disk write failed (errno \(errno))") }
                done += n
            }
        }
        let received = progress.withLock { $0 += Int64(length); return $0 }
        if received >= total { finish(nil) }
    }

    func fail(_ error: Error) { finish(error) }

    var isComplete: Bool { state.withLock { $0.done && $0.error == nil } }

    private func finish(_ error: Error?) {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            if s.done { return [] }
            s.done = true; s.error = error
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { error == nil ? $0.resume() : $0.resume(throwing: error!) }
    }

    func waitUntilComplete() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let immediate: Result<Void, Error>? = state.withLock { s in
                if s.done { return s.error.map { .failure($0) } ?? .success(()) }
                s.waiters.append(cont)
                return nil
            }
            if let immediate { cont.resume(with: immediate) }
        }
    }

    /// Closes files and moves parts into place.
    func finalize() throws {
        let fm = FileManager.default
        for (i, fd) in fds {
            Darwin.close(fd)
            guard let part = partURLs[i], let target = targets[i] else { continue }
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try fm.moveItem(at: part, to: target)
        }
        fds.removeAll()
    }

    func discard() {
        for (_, fd) in fds { Darwin.close(fd) }
        fds.removeAll()
        partURLs.values.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
