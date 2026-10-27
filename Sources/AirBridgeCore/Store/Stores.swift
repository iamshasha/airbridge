import Foundation

public struct TrustedDevice: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var fingerprint: String
    public var platform: String
    public var addedAt: Date
    /// Accept incoming files without asking (auto download).
    public var autoAccept: Bool = true
    /// May list and pull from our shared folder.
    public var allowBrowse: Bool = true
    /// Put received text straight on the clipboard.
    public var autoClipboard: Bool = false
    /// Last known direct address, so we can reach the device when discovery is quiet.
    public var lastHost: String?
    public var lastPort: UInt16?
}

public enum ReceivePolicy: String, Codable, Sendable, CaseIterable {
    case everyone, trustedOnly, off
    public var label: String {
        switch self {
        case .everyone: return "Everyone (ask for unknown devices)"
        case .trustedOnly: return "Trusted devices only"
        case .off: return "Receiving off"
        }
    }
}

/// Watched local folder that is pushed automatically to a trusted device (auto upload).
public struct SyncRule: Codable, Sendable, Identifiable, Hashable {
    public var id: String = UUID().uuidString
    public var deviceId: String
    public var folder: String
    public var enabled: Bool = true
    public init(deviceId: String, folder: String) { self.deviceId = deviceId; self.folder = folder }
}

public struct Settings: Codable, Sendable {
    public var deviceName: String
    public var receivePolicy: ReceivePolicy = .everyone
    public var downloadFolder: String
    public var sharedFolder: String?
    public var port: UInt16 = 47820
    public var parallelStreams: Int = 4
    public var bluetoothDiscovery: Bool = true
    public var syncRules: [SyncRule] = []
    /// Base URL of the internet relay (see relay/README.md), e.g. https://airbridge-relay.you.workers.dev
    public var relayURL: String = ""

    init(deviceName: String, downloadFolder: String, sharedFolder: String?) {
        self.deviceName = deviceName
        self.downloadFolder = downloadFolder
        self.sharedFolder = sharedFolder
    }

    // Tolerates settings files written by older builds (missing keys fall back to defaults).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        downloadFolder = try c.decode(String.self, forKey: .downloadFolder)
        sharedFolder = try c.decodeIfPresent(String.self, forKey: .sharedFolder)
        receivePolicy = try c.decodeIfPresent(ReceivePolicy.self, forKey: .receivePolicy) ?? .everyone
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 47820
        parallelStreams = try c.decodeIfPresent(Int.self, forKey: .parallelStreams) ?? 4
        bluetoothDiscovery = try c.decodeIfPresent(Bool.self, forKey: .bluetoothDiscovery) ?? true
        syncRules = try c.decodeIfPresent([SyncRule].self, forKey: .syncRules) ?? []
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? ""
    }
}

/// JSON-file persistence under Application Support/AirBridge.
public final class Store: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirBridge")
    }

    /// State shared between an app and its extensions (same identity and trusted devices).
    /// Falls back to `defaultDirectory` when the app group isn't provisioned.
    public static func sharedDirectory(appGroup: String) -> URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library/Application Support/AirBridge") ?? defaultDirectory
    }

    public func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
