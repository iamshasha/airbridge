import CryptoKit
import XCTest
@testable import AirBridgeCore

@MainActor
final class LoopbackTests: XCTestCase {
    var temp: URL!

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("airbridge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func makeNode(_ name: String) async throws -> Node {
        let dir = temp.appendingPathComponent(name)
        let node = try Node(store: Store(directory: dir.appendingPathComponent("state")), defaultName: name, platform: "mac")
        node.settings.port = 0
        node.settings.downloadFolder = dir.appendingPathComponent("Downloads").path
        node.start(discovery: false)
        for _ in 0 ..< 100 where node.listeningPort == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(node.listeningPort)
        return node
    }

    func addressOf(_ node: Node) -> Peer {
        var peer = Peer(id: node.identity.id, name: node.settings.deviceName, platform: "mac")
        peer.endpoints[.manual] = [.host("127.0.0.1", node.listeningPort!)]
        return peer
    }

    /// Accepts the next prompt that shows up on `node`.
    func autoRespond(_ node: Node, accept: Bool = true) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                if let p = node.prompts.first { node.respond(to: p, accept: accept); return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func writeRandomFile(_ url: URL, size: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
        try data.write(to: url)
    }

    func digest(_ url: URL) throws -> String { Data(SHA256.hash(data: try Data(contentsOf: url))).hex }

    func testSASMatchesAndPairingTrustsBothSides() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        let responder = autoRespond(b)
        var shownCode: String?
        try await a.pair(with: addressOf(b)) { shownCode = $0 }
        responder.cancel()
        XCTAssertEqual(shownCode?.count, 6)
        XCTAssertEqual(a.trusted[b.identity.id]?.fingerprint, b.identity.fingerprint)
        XCTAssertEqual(b.trusted[a.identity.id]?.fingerprint, a.identity.fingerprint)
    }

    func testUntrustedOfferNeedsApprovalAndCanBeDeclined() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        let file = temp.appendingPathComponent("x.bin")
        try writeRandomFile(file, size: 1000)
        let responder = autoRespond(b, accept: false)
        do {
            try await a.send([file], to: addressOf(b))
            XCTFail("expected decline")
        } catch AirBridgeError.declined {}
        responder.cancel()
        XCTAssertEqual(a.transfers.first?.state, .declined)
    }

    func testTrustedFolderTransferWithParallelStreamsIsByteExact() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        let responder = autoRespond(b)
        try await a.pair(with: addressOf(b)) { _ in }
        responder.cancel()

        let folder = temp.appendingPathComponent("Album")
        try writeRandomFile(folder.appendingPathComponent("big.bin"), size: 48 << 20 | 12345)
        try writeRandomFile(folder.appendingPathComponent("nested/small.txt"), size: 17)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("zero.dat").path, contents: Data())

        // Trusted + autoAccept: no prompt should be needed.
        let record = try await a.send([folder], to: addressOf(b))
        XCTAssertEqual(record.state, .done)

        let received = URL(fileURLWithPath: b.settings.downloadFolder).appendingPathComponent("Album")
        XCTAssertEqual(try digest(received.appendingPathComponent("big.bin")), try digest(folder.appendingPathComponent("big.bin")))
        XCTAssertEqual(try digest(received.appendingPathComponent("nested/small.txt")), try digest(folder.appendingPathComponent("nested/small.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.appendingPathComponent("empty").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.appendingPathComponent("zero.dat").path))

        // Sending again must not overwrite: it lands as "Album (2)".
        try await a.send([folder], to: addressOf(b))
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.deletingLastPathComponent().appendingPathComponent("Album (2)/big.bin").path))
    }

    func testTextAndBrowseAndPull() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        let responder = autoRespond(b)
        try await a.pair(with: addressOf(b)) { _ in }
        responder.cancel()

        try await a.sendText("hello from alpha", to: addressOf(b))
        XCTAssertEqual(b.inbox.first?.text, "hello from alpha")

        let shared = temp.appendingPathComponent("BetaShared")
        try writeRandomFile(shared.appendingPathComponent("doc.pdf"), size: 3 << 20)
        b.settings.sharedFolder = shared.path
        let entries = try await a.browse(addressOf(b))
        XCTAssertEqual(entries.map(\.name), ["doc.pdf"])

        let record = try await a.pull(["doc.pdf"], from: addressOf(b))
        XCTAssertEqual(record.state, .done)
        let got = URL(fileURLWithPath: a.settings.downloadFolder).appendingPathComponent("doc.pdf")
        XCTAssertEqual(try digest(got), try digest(shared.appendingPathComponent("doc.pdf")))

        // Escaping the shared folder is refused.
        do { _ = try await a.pull(["../../etc/passwd"], from: addressOf(b)); XCTFail() } catch {}
    }

    func testUnpairingTellsTheOtherDevice() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        let responder = autoRespond(b)
        try await a.pair(with: addressOf(b)) { _ in }
        responder.cancel()
        var notified: String?
        b.onUnpairedByPeer = { notified = $0 }
        a.unpair(b.identity.id)
        for _ in 0 ..< 200 where b.trusted[a.identity.id] != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(b.trusted[a.identity.id])
        XCTAssertEqual(notified, "Alpha")
    }

    func testStalePairingIsDroppedWhenPeerRefuses() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        let responder = autoRespond(b)
        try await a.pair(with: addressOf(b)) { _ in }
        responder.cancel()
        b.removeTrust(a.identity.id) // B forgot A, and the notice never arrived
        do { _ = try await a.browse(addressOf(b)); XCTFail("expected notPaired") } catch AirBridgeError.notTrusted {}
        XCTAssertNil(a.trusted[b.identity.id], "A should drop the stale pairing")
    }

    func testUntrustedCannotBrowse() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        b.settings.sharedFolder = temp.path
        do { _ = try await a.browse(addressOf(b)); XCTFail("untrusted browse should fail") } catch {}
    }

    func testSyncRuleUploadsOnlyChanges() async throws {
        let (changes, manifest) = try Node.scanChanges(folder: temp, previous: [:])
        XCTAssertTrue(changes.items.isEmpty)
        let file = temp.appendingPathComponent("a.txt")
        try writeRandomFile(file, size: 10)
        let (first, m1) = try Node.scanChanges(folder: temp, previous: manifest)
        XCTAssertEqual(first.items.map(\.path), ["\(temp.lastPathComponent)/a.txt"])
        let (second, _) = try Node.scanChanges(folder: temp, previous: m1)
        XCTAssertTrue(second.items.isEmpty)
    }

    func testSpeedTestMeasuresBothDirections() async throws {
        let a = try await makeNode("Alpha"), b = try await makeNode("Beta")
        var phases = Set<String>()
        let result = try await a.speedTest(with: addressOf(b)) { p in phases.insert(p.phase == .upload ? "up" : "down") }
        XCTAssertGreaterThan(result.upload, 1_000_000)
        XCTAssertGreaterThan(result.download, 1_000_000)
        XCTAssertEqual(phases, ["up", "down"])
        XCTAssertTrue(b.transfers.isEmpty, "speed tests don't show up as transfers")
        XCTAssertEqual(SpeedUnit.bytes.format(112_400_000), "112 MB/s")
        XCTAssertEqual(SpeedUnit.bits.format(112_400_000), "899 Mbps")
        XCTAssertEqual(SpeedUnit.bits.format(125_000_000), "1.00 Gbps")
    }

    func testUpdateVersionsAndReleaseParsing() throws {
        XCTAssertTrue(UpdateChecker.isNewer("v0.10.0", than: "0.9.2"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.3.0", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.2.0", than: "0.3.0"))
        let json = Data("""
        {"tag_name":"v0.4.0","body":"Faster","html_url":"https://github.com/iamshasha/airbridge/releases/tag/v0.4.0","draft":false,"prerelease":false,
         "assets":[{"name":"AirBridge-macOS.zip","size":1200,"browser_download_url":"https://github.com/x/AirBridge-macOS.zip"}]}
        """.utf8)
        let update = try XCTUnwrap(UpdateChecker.parse(json, current: "0.3.0", asset: "AirBridge-macOS.zip"))
        XCTAssertEqual(update.version, "0.4.0")
        XCTAssertEqual(update.downloadSize, 1200)
        XCTAssertNil(try UpdateChecker.parse(json, current: "0.4.0", asset: "AirBridge-macOS.zip"))
        XCTAssertTrue(UpdateChecker.isDue(lastCheck: nil))
        XCTAssertFalse(UpdateChecker.isDue(lastCheck: .now.addingTimeInterval(-3600)))
    }

    func testLinkParsing() {
        let https = Node.parseLink(URL(string: "https://relay.example.workers.dev/r/AbCdEfGhIjKlMnOpQrStUv#00ff")!)
        XCTAssertEqual(https?.room, "AbCdEfGhIjKlMnOpQrStUv")
        XCTAssertEqual(https?.base.absoluteString, "https://relay.example.workers.dev")
        XCTAssertEqual(https?.fingerprint, "00ff")
        let deep = Node.parseLink(URL(string: "airbridge://join/AbCdEfGhIjKlMnOpQrStUv?relay=relay.example.workers.dev#00ff")!)
        XCTAssertEqual(deep?.base.absoluteString, "https://relay.example.workers.dev")
        XCTAssertEqual(Node.relaySocketURL(base: deep!.base, room: "R", role: "join").absoluteString,
                       "wss://relay.example.workers.dev/room/R?role=join")
    }

    func testUnsafePathsRejected() {
        XCTAssertThrowsError(try ChunkSink.safeComponents("../x"))
        XCTAssertThrowsError(try ChunkSink.safeComponents("a/../../x"))
        XCTAssertEqual(try ChunkSink.safeComponents("/abs/x"), ["abs", "x"])
    }
}
