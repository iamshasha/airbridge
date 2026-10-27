import CryptoKit
import Network
import XCTest
@testable import AirBridgeCore

/// In-process stand-in for relay/src/index.js: pairs the first two WebSockets, says "ready", pipes binary.
final class MockRelay: @unchecked Sendable {
    let listener: NWListener
    private var sockets: [NWConnection] = []
    private let queue = DispatchQueue(label: "mock-relay")
    private(set) var bytesRelayed = 0

    init() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 4 << 20
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [unowned self] conn in
            conn.start(queue: queue)
            sockets.append(conn)
            if sockets.count == 2 {
                for s in sockets { send(s, Data("ready".utf8), opcode: .text) }
                pipe(sockets[0], sockets[1]); pipe(sockets[1], sockets[0])
            }
        }
    }

    func start() async throws -> UInt16 {
        listener.start(queue: queue)
        for _ in 0 ..< 200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AirBridgeError.timeout
    }

    private func send(_ conn: NWConnection, _ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let ctx = NWConnection.ContentContext(identifier: "m", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    private func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receiveMessage { [weak self] data, ctx, _, error in
            guard let self, error == nil else { to.cancel(); return }
            let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { to.cancel(); return }
            if let data, meta?.opcode == .binary {
                XCTAssertLessThanOrEqual(data.count, 1 << 20, "messages must fit Cloudflare's 1 MiB cap")
                bytesRelayed += data.count
                send(to, data, opcode: .binary)
            }
            pipe(from, to)
        }
    }

    func stop() { listener.cancel(); sockets.forEach { $0.cancel() } }
}

@MainActor
final class RelayTests: XCTestCase {
    func testShareViaLinkThroughRelay() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("airbridge-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let relay = try MockRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let sender = try Node(store: Store(directory: temp.appendingPathComponent("s")), defaultName: "Sender", platform: "mac")
        let receiver = try Node(store: Store(directory: temp.appendingPathComponent("r")), defaultName: "Receiver", platform: "mac")
        sender.settings.relayURL = "http://127.0.0.1:\(port)"
        receiver.settings.downloadFolder = temp.appendingPathComponent("recv").path

        let file = temp.appendingPathComponent("movie.mov")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        var data = Data(count: (5 << 20) + 777)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try data.write(to: file)

        var link: URL?
        let sending = Task { @MainActor in try await sender.shareViaLink([file]) { link = $0 } }
        while link == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(link?.fragment, sender.identity.fingerprint)

        // Untrusted sender → the receiver is asked; accept it.
        Task { @MainActor in
            while receiver.prompts.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
            receiver.respond(to: receiver.prompts[0], accept: true)
        }
        try await receiver.openLink(link!)
        let record = try await sending.value
        XCTAssertEqual(record.state, .done)
        let got = try Data(contentsOf: temp.appendingPathComponent("recv/movie.mov"))
        XCTAssertEqual(SHA256.hash(data: got), SHA256.hash(data: data))
        XCTAssertGreaterThan(relay.bytesRelayed, data.count)
    }

    func testLinkWithWrongFingerprintIsRejected() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("airbridge-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let relay = try MockRelay()
        let port = try await relay.start()
        defer { relay.stop() }
        let sender = try Node(store: Store(directory: temp.appendingPathComponent("s")), defaultName: "Sender", platform: "mac")
        let receiver = try Node(store: Store(directory: temp.appendingPathComponent("r")), defaultName: "Receiver", platform: "mac")
        sender.settings.relayURL = "http://127.0.0.1:\(port)"
        let file = temp.appendingPathComponent("a.txt")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: file)

        var link: URL?
        let sending = Task { @MainActor in try? await sender.shareViaLink([file]) { link = $0 } }
        while link == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        var forged = URLComponents(url: link!, resolvingAgainstBaseURL: false)!
        forged.fragment = String(repeating: "0", count: 32)
        do {
            try await receiver.openLink(forged.url!)
            XCTFail("forged fingerprint must be rejected")
        } catch AirBridgeError.authenticationFailed {}
        _ = await sending.value
    }
}
