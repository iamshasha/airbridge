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
/// Test hooks (used by the .NET interop tests): AIRBRIDGE_HOME (state folder), AIRBRIDGE_PORT,
/// AIRBRIDGE_DOWNLOADS and AIRBRIDGE_SHARED.
func makeNode(_ name: String, dir: URL? = nil) throws -> Node {
    let env = ProcessInfo.processInfo.environment
    let home = dir ?? env["AIRBRIDGE_HOME"].map { URL(fileURLWithPath: $0) }
    let store = home.map { Store(directory: $0) } ?? Store(directory: Store.defaultDirectory.appendingPathComponent("cli"))
    let node = try Node(store: store, defaultName: name, platform: "mac")
    if let port = env["AIRBRIDGE_PORT"].flatMap(UInt16.init) { node.settings.port = port }
    if let downloads = env["AIRBRIDGE_DOWNLOADS"] { node.settings.downloadFolder = downloads }
    if let shared = env["AIRBRIDGE_SHARED"] { node.settings.sharedFolder = shared }
    return node
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
                if case .pairing(let code) = p.kind { print("PAIRCODE \(code)") }
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
        print("usage: airbridge-cli bench [MB] [streams] | receive | send <host:port> <files…> | text <host:port> <message> | speedtest <host:port> | share <relay-url> <files…> | open <link>")
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
        let node = try makeNode(ProcessInfo.processInfo.environment["AIRBRIDGE_NAME"] ?? name + " (CLI)")
        node.start(discovery: ProcessInfo.processInfo.environment["AIRBRIDGE_HOME"] == nil)
        print("Listening on port \(try await waitForPort(node)); files go to \(node.settings.downloadFolder)")
        print("FINGERPRINT \(node.identity.fingerprint)")
        autoAccept(node)
        // One line per event so other implementations' tests can follow along.
        node.onTransferFinished = { r in print("TRANSFER \(r.title) \(r.state == .done ? "done" : "\(r.state)") \(formatRate(r.bytes, r.finishedAt!.timeIntervalSince(r.startedAt)))") }
        node.onTextReceived = { item, _ in print("TEXT \(item.from): \(item.text)") }
        node.onUnpairedByPeer = { print("UNPAIRED \($0)") }
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
    case "speedtest":
        guard let target = args.first, let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) else {
            throw AirBridgeError.protocolViolation("usage: speedtest <host:port>")
        }
        let node = try makeNode(name + " (CLI)")
        let peer = try await node.addManualPeer(host: String(target[..<colon]), port: port)
        let result = try await node.speedTest(with: peer) { _ in }
        print("SPEED upload \(Int(result.upload)) download \(Int(result.download))")
        print("Upload \(SpeedUnit.bytes.format(result.upload)) (\(SpeedUnit.bits.format(result.upload))), download \(SpeedUnit.bytes.format(result.download)) (\(SpeedUnit.bits.format(result.download)))")
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

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered even when piped to a test harness
do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
