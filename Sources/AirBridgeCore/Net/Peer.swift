import Foundation
import Network

public enum DiscoverySource: String, Sendable, Hashable, CaseIterable {
    case lan, peerToPeer, bluetooth, manual, trusted

    public var label: String {
        switch self {
        case .lan: return "Wi-Fi/LAN"
        case .peerToPeer: return "Peer-to-peer Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .manual: return "Manual"
        case .trusted: return "Last known address"
        }
    }

    public var symbol: String {
        switch self {
        case .lan: return "wifi"
        case .peerToPeer: return "antenna.radiowaves.left.and.right"
        case .bluetooth: return "dot.radiowaves.right"
        case .manual: return "network"
        case .trusted: return "clock.arrow.circlepath"
        }
    }
}

/// A way to reach a peer, tried in order of preference when connecting.
public enum PeerEndpoint: Hashable, Sendable {
    case bonjour(NWEndpoint)
    case host(String, UInt16)

    var nwEndpoint: NWEndpoint {
        switch self {
        case .bonjour(let e): return e
        case .host(let h, let p): return .hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: p) ?? 47820)
        }
    }
}

public struct Peer: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var fingerprint: String?
    public var endpoints: [DiscoverySource: [PeerEndpoint]] = [:]
    public var lastSeen: Date = Date()
    public var rssi: Int?

    public init(id: String, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }

    public var sources: [DiscoverySource] { DiscoverySource.allCases.filter { endpoints[$0]?.isEmpty == false } }

    /// Fastest first: Bonjour (resolves to LAN or AWDL), then direct addresses.
    public var orderedEndpoints: [PeerEndpoint] {
        var seen = Set<PeerEndpoint>()
        return [DiscoverySource.lan, .peerToPeer, .manual, .bluetooth, .trusted]
            .flatMap { endpoints[$0] ?? [] }
            .filter { seen.insert($0).inserted }
    }

    public var platformSymbol: String {
        switch platform {
        case "ios": return "iphone"
        case "win": return "pc"
        default: return "laptopcomputer"
        }
    }
}
