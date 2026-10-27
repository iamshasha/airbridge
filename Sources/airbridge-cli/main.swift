import AirBridgeCore
import Foundation

// Headless AirBridge: benchmark, receive, send, link sharing.
//
//   airbridge-cli bench [MB] [streams]       loopback throughput test through the full encrypted stack
//   airbridge-cli receive                     listen and auto-accept everything (prints port)
//   airbridge-cli send <host:port> <files…>   send to a device by address
//   airbridge-cli text <host:port> <message>  send text
//   airbridge-cli share <relay-url> <files…>  share through an internet link
//   airbridge-cli open <link>                 receive from an internet link

@MainActor
func makeNode(_ name: String, dir: URL? = nil) throws -> Node {
    let store = dir.map { Store(directory: $0) } ?? Store(directory: Store.defaultDirectory.appendingPathComponent("cli"))
    return try Node(store: store, defaultName: name, platform: "mac")
}

@MainActor
func waitForPort(_ node: Node) async throws -> UInt16 {
    for _ in 0 ..< 200 {
        if let p = node.listeningPort { return p }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw AirBridgeError.timeout
}

@MainActor
func autoAccept(_ node: Node) {
    Task { @MainActor in
        while true {
            for p in node.prompts {
                print("Accepting: \(p.summary)")
                node.respond(to: p, accept: true)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

func formatRate(_ bytes: Int64, _ seconds: Double) -> String {
    let mbps = Double(bytes) / seconds / 1_000_000
    return String(format: "%.0f MB/s (%.2f Gbit/s)", mbps, mbps * 8 / 1000)
}

@MainActor
func bench(sizeMB: Int, streams: Int) async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("airbridge-bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let a = try makeNode("Bench A", dir: temp.appendingPathComponent("a"))
    let b = try makeNode("Bench B", dir: temp.appendingPathComponent("b"))
    for n in [a, b] { n.settings.port = 0; n.settings.parallelStreams = streams }
    b.settings.downloadFolder = temp.appendingPathComponent("recv").path
    a.start(discovery: false); b.start(discovery: false)
    let port = try await waitForPort(b)
    autoAccept(b)

    let file = temp.appendingPathComponent("payload.bin")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    var block = Data(count: 8 << 20)
    block.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 8 << 20, $0.baseAddress!) }
    for _ in 0 ..< max(1, sizeMB / 8) { handle.write(block) }
    try handle.close()
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0

    var peer = Peer(id: b.identity.id, name: "Bench B", platform: "mac")
    peer.endpoints[.manual] = [.host("127.0.0.1", port)]
    let start = Date()
    try await a.send([file], to: peer)
    let elapsed = Date().timeIntervalSince(start)
    print("Sent \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) over \(streams) stream(s) in \(String(format: "%.2f", elapsed)) s → \(formatRate(size, elapsed))")
}

@MainActor
func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else {
        print("usage: airbridge-cli bench [MB] [streams] | receive | send <host:port> <files…> | share <relay-url> <files…> | open <link>")
        return
    }
    let command = args.removeFirst()
    let name = Host.current().localizedName ?? "AirBridge CLI"
    switch command {
    case "bench":
        let size = args.first.flatMap(Int.init) ?? 1024
        let streams = args.dropFirst().first.flatMap(Int.init)
        for s in streams.map({ [$0] }) ?? [1, 4] { try await bench(sizeMB: size, streams: s) }
    case "receive":
        let node = try makeNode(name + " (CLI)")
        node.start()
        print("Listening on port \(try await waitForPort(node)); files go to \(node.settings.downloadFolder)")
        autoAccept(node)
        node.onTransferFinished = { r in print("\(r.title): \(r.state) \(formatRate(r.bytes, r.finishedAt!.timeIntervalSince(r.startedAt)))") }
        while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
    case "send":
        guard args.count >= 2, let colon = args[0].lastIndex(of: ":"), let port = UInt16(args[0][args[0].index(after: colon)...]) else {
            throw AirBridgeError.protocolViolation("usage: send <host:port> <files…>")
        }
        let node = try makeNode(name + " (CLI)")
        let peer = try await node.addManualPeer(host: String(args[0][..<colon]), port: port)
        let record = try await node.send(args.dropFirst().map { URL(fileURLWithPath: $0) }, to: peer)
        print("Done: \(formatRate(record.bytes, record.finishedAt!.timeIntervalSince(record.startedAt)))")
    case "text":
        guard args.count >= 2, let colon = args[0].lastIndex(of: ":"), let port = UInt16(args[0][args[0].index(after: colon)...]) else {
            throw AirBridgeError.protocolViolation("usage: text <host:port> <message>")
        }
        let node = try makeNode(name + " (CLI)")
        let peer = try await node.addManualPeer(host: String(args[0][..<colon]), port: port)
        try await node.sendText(args.dropFirst().joined(separator: " "), to: peer)
        print("Sent text to \(peer.name)")
    case "share":
        guard args.count >= 2 else { throw AirBridgeError.protocolViolation("usage: share <relay-url> <files…>") }
        let node = try makeNode(name + " (CLI)")
        node.settings.relayURL = args[0]
        let record = try await node.shareViaLink(args.dropFirst().map { URL(fileURLWithPath: $0) }) { link in
            print("Share this link: \(link.absoluteString)")
        }
        print("Done: \(formatRate(record.bytes, record.finishedAt!.timeIntervalSince(record.startedAt)))")
    case "open":
        guard let link = args.first.flatMap(URL.init(string:)) else { throw AirBridgeError.protocolViolation("usage: open <link>") }
        let node = try makeNode(name + " (CLI)")
        autoAccept(node)
        try await node.openLink(link)
        print("Received into \(node.settings.downloadFolder)")
    default:
        print("unknown command \(command)")
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
