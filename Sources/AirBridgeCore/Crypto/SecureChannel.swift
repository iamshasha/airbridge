import CryptoKit
import Foundation

/// Authenticated, encrypted channel over a `Wire` (see PROTOCOL.md §2.2–2.3).
final class SecureChannel: @unchecked Sendable {
    enum FrameType: UInt8 { case control = 1, chunk = 2 }

    let wire: Wire
    let peer: PeerHello
    let isClient: Bool
    /// 6-digit pairing code both sides derive from the transcript.
    let sas: String

    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private let sendLock = NSLock()
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    private static let label = Data("AirBridge/1".utf8)

    private init(wire: Wire, peer: PeerHello, isClient: Bool, sendKey: SymmetricKey, recvKey: SymmetricKey, sas: String) {
        self.wire = wire
        self.peer = peer
        self.isClient = isClient
        self.sendKey = sendKey
        self.recvKey = recvKey
        self.sas = sas
    }

    struct LocalInfo: Sendable {
        var identity: DeviceIdentity
        var name: String
        var platform: String
        var port: UInt16
    }

    static func handshake(wire: Wire, local: LocalInfo, isClient: Bool) async throws -> SecureChannel {
        let eph = P256.KeyAgreement.PrivateKey()
        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let hello = PeerHello(v: 1, id: local.identity.id, name: local.name, platform: local.platform, port: local.port,
                              sigKey: local.identity.publicKeyRaw, ephKey: eph.publicKey.rawRepresentation, nonce: nonce)
        let myHello = try JSONEncoder().encode(hello)
        try await wire.sendFrame(myHello)
        let theirHello = try await wire.receiveFrame()
        let peer: PeerHello
        do { peer = try JSONDecoder().decode(PeerHello.self, from: theirHello) } catch {
            throw AirBridgeError.protocolViolation("bad hello")
        }
        guard peer.v == 1 else { throw AirBridgeError.protocolViolation("unsupported version \(peer.v)") }
        guard peer.id != local.identity.id else { throw AirBridgeError.protocolViolation("connected to self") }

        let transcript = transcriptHash(client: isClient ? myHello : theirHello, server: isClient ? theirHello : myHello)

        struct Auth: Codable { var sig: Data }
        let signature = try local.identity.signingKey.signature(for: transcript)
        try await wire.sendFrame(try JSONEncoder().encode(Auth(sig: signature.rawRepresentation)))
        let auth = try JSONDecoder().decode(Auth.self, from: try await wire.receiveFrame())
        guard let peerKey = try? P256.Signing.PublicKey(rawRepresentation: peer.sigKey),
              let peerSig = try? P256.Signing.ECDSASignature(rawRepresentation: auth.sig),
              peerKey.isValidSignature(peerSig, for: transcript),
              let peerEph = try? P256.KeyAgreement.PublicKey(rawRepresentation: peer.ephKey)
        else { throw AirBridgeError.authenticationFailed }

        let shared = try eph.sharedSecretFromKeyAgreement(with: peerEph)
        let c2s = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("AirBridge/1 c2s".utf8), outputByteCount: 32)
        let s2c = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("AirBridge/1 s2c".utf8), outputByteCount: 32)
        return SecureChannel(wire: wire, peer: peer, isClient: isClient,
                             sendKey: isClient ? c2s : s2c, recvKey: isClient ? s2c : c2s,
                             sas: sasCode(transcript: transcript))
    }

    static func transcriptHash(client: Data, server: Data) -> Data {
        var t = label
        t.appendBE(UInt32(client.count)); t.append(client)
        t.appendBE(UInt32(server.count)); t.append(server)
        return Data(SHA256.hash(data: t))
    }

    static func sasCode(transcript: Data) -> String {
        let digest = Data(SHA256.hash(data: Data("AirBridge/SAS".utf8) + transcript))
        let value = digest.readBE(UInt32.self, at: 0) % 1_000_000
        return String(format: "%06u", value)
    }

    private static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var n = Data(count: 4)
        n.appendBE(counter)
        return try! AES.GCM.Nonce(data: n)
    }

    // MARK: encrypted frames

    /// Seals and queues one frame. Sealing and queueing happen under one lock so counters match wire order.
    func send(type: FrameType, payload: Data) async throws {
        var plain = Data(capacity: payload.count + 1)
        plain.append(type.rawValue)
        plain.append(payload)
        try await send(plaintext: plain)
    }

    /// `plain` must already start with the frame type byte.
    func send(plaintext plain: Data) async throws {
        try await wire.reserve()
        try sendLock.withLock {
            let box = try AES.GCM.seal(plain, using: sendKey, nonce: Self.nonce(sendCounter))
            sendCounter += 1
            var f = Data(capacity: plain.count + 20)
            f.appendBE(UInt32(plain.count + 16))
            f.append(box.ciphertext)
            f.append(box.tag)
            wire.enqueue(f)
        }
    }

    func receive() async throws -> (FrameType, Data) {
        let body = try await wire.receiveFrame()
        guard body.count >= 17 else { throw AirBridgeError.protocolViolation("short frame") }
        let box = try AES.GCM.SealedBox(nonce: Self.nonce(recvCounter),
                                        ciphertext: body.prefix(body.count - 16),
                                        tag: body.suffix(16))
        recvCounter += 1
        let plain: Data
        do { plain = try AES.GCM.open(box, using: recvKey) } catch { throw AirBridgeError.authenticationFailed }
        guard let type = FrameType(rawValue: plain[plain.startIndex]) else {
            throw AirBridgeError.protocolViolation("unknown frame type")
        }
        return (type, plain.dropFirst())
    }

    func send(_ message: ControlMessage) async throws {
        try await send(type: .control, payload: try JSONEncoder().encode(message))
    }

    func receiveControl() async throws -> ControlMessage {
        let (type, payload) = try await receive()
        guard type == .control else { throw AirBridgeError.protocolViolation("expected control frame") }
        return try JSONDecoder().decode(ControlMessage.self, from: payload)
    }

    func close() { wire.cancel() }
}
