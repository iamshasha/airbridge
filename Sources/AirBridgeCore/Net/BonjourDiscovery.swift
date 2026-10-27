import Foundation
import Network

public let airBridgeServiceType = "_airbridge._tcp"

/// Browses `_airbridge._tcp` on infrastructure networks and Apple peer-to-peer Wi-Fi (AWDL).
final class BonjourDiscovery: @unchecked Sendable {
    struct Found: Sendable {
        var id: String
        var name: String
        var platform: String
        var fingerprint: String?
        var endpoint: NWEndpoint
        var peerToPeer: Bool
    }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "airbridge.bonjour")
    private let onChange: @Sendable ([Found]) -> Void

    init(onChange: @escaping @Sendable ([Found]) -> Void) { self.onChange = onChange }

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: airBridgeServiceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [onChange] results, _ in
            let found: [Found] = results.compactMap { result in
                guard case .bonjour(let txt) = result.metadata, let id = txt["id"] else { return nil }
                let p2p = !result.interfaces.isEmpty && result.interfaces.allSatisfy { $0.name.hasPrefix("awdl") || $0.name.hasPrefix("llw") }
                return Found(id: id, name: txt["n"] ?? id, platform: txt["pl"] ?? "mac", fingerprint: txt["fp"],
                             endpoint: result.endpoint, peerToPeer: p2p)
            }
            onChange(found)
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { browser.cancel() }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() { browser?.cancel(); browser = nil }
}

/// Local interface addresses, shared over Bluetooth so peers without working mDNS can still dial us.
enum LocalAddresses {
    static func current(limit: Int = 4) -> [String] {
        var result: [(priority: Int, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ptr.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("bridge") || name.hasPrefix("pdp_ip") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            // Prefer IPv4 on Wi-Fi/Ethernet; skip link-local IPv6 which needs a scope id the peer can't know.
            if address.hasPrefix("fe80") { continue }
            let priority = (family == UInt8(AF_INET) ? 0 : 2) + (name.hasPrefix("en") ? 0 : 1)
            result.append((priority, address))
        }
        return result.sorted { $0.priority < $1.priority }.prefix(limit).map(\.address)
    }
}
