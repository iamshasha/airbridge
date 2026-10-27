import Foundation
import Network

/// async/await byte stream over an `NWConnection`: direct TCP, or a WebSocket to the internet relay
/// (relay/ in this repo), which pipes two sockets together. Either way the caller sees a plain byte stream.
final class Wire: @unchecked Sendable {
    let connection: NWConnection
    let isRelay: Bool
    private let queue: DispatchQueue
    private let window: SendWindow
    /// Relay only: bytes received in WebSocket messages but not consumed yet.
    private var buffer = Data()

    static let maxFrame = 16 << 20
    /// Cloudflare caps WebSocket messages at 1 MiB; stay well below.
    static let relayMessageSize = 256 << 10

    init(_ connection: NWConnection, maxInFlight: Int = 8, isRelay: Bool = false) {
        self.connection = connection
        self.isRelay = isRelay
        self.queue = DispatchQueue(label: "airbridge.wire", qos: .userInitiated)
        self.window = SendWindow(limit: maxInFlight)
    }

    /// Joins a relay room. Returns once the relay says the other side is connected.
    static func connectRelay(_ url: URL, waitForPeer: TimeInterval) async throws -> Wire {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 4 << 20
        let tls = url.scheme == "wss" ? NWProtocolTLS.Options() : nil
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let wire = Wire(NWConnection(to: .url(url), using: params), isRelay: true)
        try await wire.start(timeout: 15)
        // The relay sends a text "ready" once both sides are in the room.
        let deadline = Date().addingTimeInterval(waitForPeer)
        while true {
            let (data, isText) = try await wire.receiveMessage(timeout: deadline.timeIntervalSinceNow)
            if isText, String(decoding: data, as: UTF8.self) == "ready" { return wire }
            if isText, String(decoding: data, as: UTF8.self).hasPrefix("error") {
                wire.cancel()
                throw AirBridgeError.connectFailed(String(decoding: data, as: UTF8.self))
            }
        }
    }

    private func receiveMessage(timeout: TimeInterval = .infinity) async throws -> (Data, isText: Bool) {
        guard timeout > 0 else { cancel(); throw AirBridgeError.timeout }
        let timer = timeout.isFinite ? DispatchWorkItem { [weak self] in self?.cancel() } : nil
        if let timer { queue.asyncAfter(deadline: .now() + timeout, execute: timer) }
        defer { timer?.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            connection.receiveMessage { content, context, _, error in
                if let error { return cont.resume(throwing: AirBridgeError.connectFailed(error.localizedDescription)) }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if meta?.opcode == .close || (content == nil && meta == nil) {
                    return cont.resume(throwing: AirBridgeError.connectionClosed)
                }
                cont.resume(returning: (content ?? Data(), meta?.opcode == .text))
            }
        }
    }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.connectionTimeout = 6
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        return params
    }

    static func connect(to endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> Wire {
        let wire = Wire(NWConnection(to: endpoint, using: tcpParameters()))
        try await wire.start(timeout: timeout)
        return wire
    }

    func start(timeout: TimeInterval = 8) async throws {
        let resumed = Locked(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            @Sendable func finish(_ result: Result<Void, Error>) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { cont.resume(with: result) }
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(AirBridgeError.connectFailed(e.localizedDescription)))
                case .waiting(let e):
                    // Outgoing connections that cannot route sit in .waiting forever; fail fast.
                    finish(.failure(AirBridgeError.connectFailed(e.localizedDescription)))
                    self?.connection.cancel()
                case .cancelled: finish(.failure(AirBridgeError.connectionClosed))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                finish(.failure(AirBridgeError.timeout))
                if resumed.current { self?.cancelIfNotReady() }
            }
        }
    }

    private func cancelIfNotReady() {
        if case .ready = connection.state { return }
        connection.cancel()
    }

    func cancel() { connection.cancel() }

    var remoteDescription: String { "\(connection.endpoint)" }

    // MARK: sending

    /// Queue bytes for sending, in call order. Suspends only while too many sends are in flight.
    func send(_ data: Data) async throws {
        try await reserve()
        enqueue(data)
    }

    /// Two-step send for callers that must assign sequence numbers in wire order:
    /// `reserve()` a slot, then `enqueue` while holding their own ordering lock.
    func reserve() async throws { try await window.acquire() }

    func enqueue(_ data: Data) {
        let done: NWConnection.SendCompletion = .contentProcessed { [window] error in
            window.release(error: error.map { AirBridgeError.connectFailed($0.localizedDescription) })
        }
        guard isRelay else { return connection.send(content: data, completion: done) }
        let context = NWConnection.ContentContext(identifier: "bin", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + Wire.relayMessageSize, data.endIndex)
            connection.send(content: data[offset ..< end], contentContext: context, isComplete: true,
                            completion: end == data.endIndex ? done : .idempotent)
            offset = end
        }
    }

    /// Wait until everything queued so far has been handed to the network stack.
    func flush() async throws { try await window.drain() }

    // MARK: receiving

    func receive(exactly count: Int) async throws -> Data {
        if count == 0 { return Data() }
        if isRelay {
            while buffer.count < count {
                let (data, isText) = try await receiveMessage()
                if !isText { buffer.append(data) }
            }
            let out = buffer.prefix(count)
            buffer.removeFirst(count)
            return Data(out)
        }
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: AirBridgeError.connectFailed(error.localizedDescription))
                } else if let content, content.count == count {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(throwing: AirBridgeError.connectionClosed)
                } else {
                    cont.resume(throwing: AirBridgeError.protocolViolation("short read"))
                }
            }
        }
    }

    func receiveFrame() async throws -> Data {
        let header = try await receive(exactly: 4)
        let length = Int(header.readBE(UInt32.self, at: 0))
        guard length <= Wire.maxFrame else { throw AirBridgeError.protocolViolation("frame too large") }
        return try await receive(exactly: length)
    }

    func sendFrame(_ payload: Data) async throws {
        var frame = Data(capacity: payload.count + 4)
        frame.appendBE(UInt32(payload.count))
        frame.append(payload)
        try await send(frame)
    }
}

/// Bounded number of outstanding `NWConnection.send` calls so large transfers keep the pipe full
/// without buffering whole files in memory.
final class SendWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var inFlight = 0
    private var error: Error?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var drainers: [CheckedContinuation<Void, Error>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let error { lock.unlock(); cont.resume(throwing: error); return }
            if inFlight < limit {
                inFlight += 1
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func release(error newError: Error?) {
        lock.lock()
        var resumeWaiters: [CheckedContinuation<Void, Error>] = []
        var resumeDrainers: [CheckedContinuation<Void, Error>] = []
        if let newError, error == nil { error = newError }
        if let error {
            resumeWaiters = waiters; waiters = []
            resumeDrainers = drainers; drainers = []
            inFlight -= 1
            lock.unlock()
            resumeWaiters.forEach { $0.resume(throwing: error) }
            resumeDrainers.forEach { $0.resume(throwing: error) }
            return
        }
        if !waiters.isEmpty {
            resumeWaiters = [waiters.removeFirst()] // hand the slot over directly
        } else {
            inFlight -= 1
            if inFlight == 0 { resumeDrainers = drainers; drainers = [] }
        }
        lock.unlock()
        resumeWaiters.forEach { $0.resume() }
        resumeDrainers.forEach { $0.resume() }
    }

    func drain() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let error { lock.unlock(); cont.resume(throwing: error); return }
            if inFlight == 0 { lock.unlock(); cont.resume(); return }
            drainers.append(cont)
            lock.unlock()
        }
    }
}
