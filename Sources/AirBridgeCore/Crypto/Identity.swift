import CryptoKit
import Foundation

/// Long-term device identity: a stable id plus a P-256 signing key whose fingerprint is what peers trust.
public struct DeviceIdentity: Sendable {
    public let id: String
    public let signingKey: P256.Signing.PrivateKey

    public var publicKeyRaw: Data { signingKey.publicKey.rawRepresentation }
    public var fingerprint: String { DeviceIdentity.fingerprint(of: publicKeyRaw) }

    public static func fingerprint(of rawPublicKey: Data) -> String {
        Data(SHA256.hash(data: rawPublicKey).prefix(16)).hex
    }

    public static func generate() -> DeviceIdentity {
        DeviceIdentity(id: UUID().uuidString, signingKey: P256.Signing.PrivateKey())
    }

    private struct Stored: Codable { var id: String; var key: Data }

    /// Loads the identity from `url`, creating it (mode 0600) on first launch.
    public static func loadOrCreate(at url: URL) throws -> DeviceIdentity {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: stored.key) {
            return DeviceIdentity(id: stored.id, signingKey: key)
        }
        let identity = generate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(id: identity.id, key: identity.signingKey.rawRepresentation))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return identity
    }
}

/// What the remote side proved about itself during the handshake.
public struct PeerHello: Codable, Sendable {
    public var v: Int
    public var id: String
    public var name: String
    public var platform: String
    public var port: UInt16
    public var sigKey: Data
    public var ephKey: Data
    public var nonce: Data

    public var fingerprint: String { DeviceIdentity.fingerprint(of: sigKey) }
}
