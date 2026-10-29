import Foundation

/// How speeds are shown: megabytes per second (like file sizes) or megabits per second (like network plans).
public enum SpeedUnit: String, Codable, Sendable, CaseIterable {
    case bytes, bits

    public var label: String { self == .bytes ? "MB/s" : "Mbps" }

    /// "112 MB/s" or "896 Mbps". Decimal units throughout, like Finder and internet providers.
    public func format(_ bytesPerSecond: Double) -> String {
        let value = self == .bytes ? bytesPerSecond : bytesPerSecond * 8
        let units = self == .bytes ? ["B/s", "KB/s", "MB/s", "GB/s"] : ["bps", "kbps", "Mbps", "Gbps"]
        var v = max(0, value)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let digits = v >= 100 || i == 0 ? "%.0f" : v >= 10 ? "%.1f" : "%.2f"
        return String(format: digits, v) + " " + units[i]
    }
}

public struct SpeedTestResult: Sendable, Equatable {
    /// Bytes per second from this device to the other one.
    public var upload: Double
    /// Bytes per second from the other device to this one.
    public var download: Double
}

public struct SpeedTestProgress: Sendable, Equatable {
    public enum Phase: Sendable { case upload, download }
    public var phase: Phase
    /// 0...1 within the phase.
    public var fraction: Double
    /// Rate so far in this phase, bytes per second.
    public var bytesPerSecond: Double
}

/// Endless zero-filled chunks up to `total` bytes. Encryption makes them incompressible on the wire.
final class SpeedSource: @unchecked Sendable {
    let total: Int64
    let sent = Locked<Int64>(0)
    private let handedOut = Locked<Int64>(0)
    private let chunk: Data

    init(total: Int64) {
        self.total = total
        var data = Data(count: 13 + chunkSize)
        data[0] = SecureChannel.FrameType.chunk.rawValue
        chunk = data
    }

    func next() -> Int? {
        handedOut.withLock { done in
            guard done < total else { return nil }
            let n = Int(min(Int64(chunkSize), total - done))
            done += Int64(n)
            return n
        }
    }

    func plaintext(length: Int) -> Data { length == chunkSize ? chunk : chunk.prefix(13 + length) }
}

/// Counts bytes arriving on any number of streams until `total` is reached.
final class SpeedSink: @unchecked Sendable {
    private struct State {
        var outcome: Result<Void, Error>?
        var waiter: CheckedContinuation<Void, Error>?
    }

    let total: Int64
    let received = Locked<Int64>(0)
    private let state = Locked(State())

    init(total: Int64) { self.total = total }

    var isComplete: Bool { received.current >= total }

    func add(_ n: Int) {
        let now = received.withLock { $0 += Int64(n); return $0 }
        if now >= total { finish(.success(())) }
    }

    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, Error>) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Error>? in
            if s.outcome != nil { return nil }
            s.outcome = result
            let w = s.waiter
            s.waiter = nil
            return w
        }
        waiter?.resume(with: result)
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let ready = state.withLock { s -> Result<Void, Error>? in
                if s.outcome == nil { s.waiter = c }
                return s.outcome
            }
            if let ready { c.resume(with: ready) }
        }
    }
}

extension Node {
    nonisolated static let speedTestLimit: Int64 = 1 << 30

    /// Measures throughput to and from `peer` over the same encrypted parallel streams files use.
    /// A short probe sizes each phase to take about three seconds on this network.
    public func speedTest(with peer: Peer, progress: @escaping @MainActor (SpeedTestProgress) -> Void) async throws -> SpeedTestResult {
        let upload = try await measure(peer, phase: .upload, progress: progress)
        let download = try await measure(peer, phase: .download, progress: progress)
        return SpeedTestResult(upload: upload, download: download)
    }

    private func measure(_ peer: Peer, phase: SpeedTestProgress.Phase,
                         progress: @escaping @MainActor (SpeedTestProgress) -> Void) async throws -> Double {
        let probe = try await run(peer, phase: phase, total: 8 << 20, report: nil)
        let total = min(Node.speedTestLimit, max(16 << 20, Int64(probe * 3)))
        return try await run(peer, phase: phase, total: total) { fraction, rate in
            progress(SpeedTestProgress(phase: phase, fraction: fraction, bytesPerSecond: rate))
        }
    }

    /// One timed run. Returns bytes per second.
    private func run(_ peer: Peer, phase: SpeedTestProgress.Phase, total: Int64,
                     report: (@MainActor (Double, Double) -> Void)?) async throws -> Double {
        let (control, endpoint) = try await connect(peer.orderedEndpoints, fingerprint: peer.fingerprint ?? trusted[peer.id]?.fingerprint)
        defer { control.close() }
        let transferId = UUID().uuidString
        var request = ControlMessage("speedtest")
        request.transferId = transferId
        request.total = total
        request.mode = phase == .upload ? "upload" : "download"
        request.streams = max(1, settings.parallelStreams)
        try await control.send(request)
        let reply = try await control.receiveControl()
        guard reply.t == "accept" else {
            if reply.t == "error", reply.reason?.hasPrefix("unknown request") == true {
                throw AirBridgeError.protocolViolation("\(peer.name) needs a newer AirBridge for speed tests")
            }
            throw AirBridgeError.declined(reply.reason ?? "")
        }
        let streams = min(16, max(1, reply.streams ?? 1))
        let start = Date()
        let counter: Locked<Int64>
        let role: Role
        let sink = SpeedSink(total: total)
        if phase == .upload {
            let source = SpeedSource(total: total)
            role = .blast(source); counter = source.sent
        } else {
            role = .drain(sink); counter = sink.received
        }
        let ticker = report.map { report in
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    let elapsed = Date().timeIntervalSince(start)
                    let bytes = counter.current
                    report(Double(bytes) / Double(total), elapsed > 0 ? Double(bytes) / elapsed : 0)
                }
            }
        }
        defer { ticker?.cancel() }

        let fingerprint = control.peer.fingerprint
        let opened = Locked<[SecureChannel]>([])
        defer { opened.current.forEach { $0.close() } }
        let tasks = (0 ..< streams).map { _ in
            Task.detached { [self] in
                let (channel, _) = try await connect([endpoint], fingerprint: fingerprint)
                opened.withLock { $0.append(channel) }
                var bind = ControlMessage("stream")
                bind.transferId = transferId
                try await channel.send(bind)
                try await Self.runStream(channel, role: role)
            }
        }
        if phase == .upload {
            // The receiver says "complete" once every byte has arrived.
            let confirmation = Task.detached { try await control.receiveControl() }
            for task in tasks { do { try await task.value } catch { confirmation.cancel(); control.close(); throw error } }
            let done = try await confirmation.value
            guard done.t == "complete" else { throw AirBridgeError.protocolViolation(done.reason ?? "speed test failed") }
        } else {
            for task in tasks { Task.detached { do { try await task.value } catch { sink.fail(error) } } }
            try await sink.wait()
            var done = ControlMessage("complete")
            done.transferId = transferId
            try? await control.send(done)
            try? await control.wire.flush()
        }
        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        report?(1, Double(total) / elapsed)
        return Double(total) / elapsed
    }

    /// Server side: count an upload, or stream a download, on the client's stream connections.
    func handleSpeedTest(_ msg: ControlMessage, on control: SecureChannel) async throws {
        guard settings.receivePolicy != .off else { try await control.send(.error("Receiving is turned off")); return }
        guard let transferId = msg.transferId, let total = msg.total, total > 0, total <= Node.speedTestLimit,
              msg.mode == "upload" || msg.mode == "download" else {
            try await control.send(.error("Bad speed test request")); return
        }
        let streams = min(16, max(1, msg.streams ?? settings.parallelStreams))
        let sink = SpeedSink(total: total)
        let role: Role = msg.mode == "upload" ? .drain(sink) : .blast(SpeedSource(total: total))
        active.withLock { $0[transferId] = ActiveTransfer(fingerprint: control.peer.fingerprint, role: role) }
        defer { active.withLock { $0[transferId] = nil } }
        var accept = ControlMessage("accept")
        accept.transferId = transferId
        accept.streams = streams
        try await control.send(accept)
        if msg.mode == "upload" {
            // If the client disappears, its control socket closes; stop waiting.
            let watcher = Task.detached { _ = try? await control.receive(); sink.fail(AirBridgeError.connectionClosed) }
            defer { watcher.cancel() }
            try await sink.wait()
            var done = ControlMessage("complete")
            done.transferId = transferId
            try await control.send(done)
        } else {
            // The client says "complete" (or hangs up) when it has everything.
            _ = try? await control.receiveControl()
        }
    }
}
