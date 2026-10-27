import Foundation
import Network
#if canImport(CoreWLAN)
import CoreWLAN
#endif

/// What this machine's radios and interfaces can do, so the app can pick transports and
/// decide whether it can act as an AirDrop client.
public struct AdapterCapabilities: Sendable, Equatable {
    public enum AirDropSupport: String, Sendable {
        /// The OS ships AirDrop; we hand files to it (macOS / iOS).
        case native
        /// No AirDrop stack; an AWDL emulator (OpenDrop/OWL-style) would need a monitor-mode adapter.
        case unavailable
    }

    public var wifiInterface: String?
    public var wifiPoweredOn = false
    public var wifiSupports5GHz = false
    public var wifiSSIDConnected = false
    public var awdlInterfacePresent = false
    public var awdlInterfaceUp = false
    public var ethernetActive = false
    public var vpnInterfaces: [String] = []
    public var bluetoothState: String = "unknown"
    public var bluetoothLEUsable = false
    public var airDrop: AirDropSupport = .unavailable

    /// Peer-to-peer Wi-Fi without a shared access point is available.
    public var peerToPeerWiFi: Bool { awdlInterfacePresent && wifiPoweredOn }

    public var summary: [(String, String, Bool)] {
        [
            ("Wi-Fi", wifiInterface.map { "\($0)\(wifiSupports5GHz ? ", 5 GHz" : "")\(wifiSSIDConnected ? ", associated" : "")" } ?? "none", wifiPoweredOn),
            ("Peer-to-peer Wi-Fi (AWDL)", awdlInterfacePresent ? (awdlInterfaceUp ? "awdl0 up" : "awdl0 idle") : "not available", peerToPeerWiFi),
            ("Bluetooth LE", bluetoothState, bluetoothLEUsable),
            ("Ethernet", ethernetActive ? "active" : "inactive", ethernetActive),
            ("VPN / overlay", vpnInterfaces.isEmpty ? "none" : vpnInterfaces.joined(separator: ", "), !vpnInterfaces.isEmpty),
            ("AirDrop client", airDrop == .native ? "native (system AirDrop)" : "unavailable", airDrop == .native),
        ]
    }

    public static func probe(bluetoothState: String = "unknown", bluetoothLEUsable: Bool = false) -> AdapterCapabilities {
        var caps = AdapterCapabilities()
        caps.bluetoothState = bluetoothState
        caps.bluetoothLEUsable = bluetoothLEUsable

        let interfaces = interfaceFlags()
        if let awdl = interfaces["awdl0"] {
            caps.awdlInterfacePresent = true
            caps.awdlInterfaceUp = awdl & IFF_UP != 0 && awdl & IFF_RUNNING != 0
        }
        caps.vpnInterfaces = interfaces.keys.filter { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("wg") }.sorted()
        // utun0..3 exist on every Mac for system services; only count extra tunnels as VPNs.
        caps.vpnInterfaces = caps.vpnInterfaces.filter { name in
            guard name.hasPrefix("utun"), let n = Int(name.dropFirst(4)) else { return true }
            return n >= 4 && hasIPv4(name)
        }

        #if canImport(CoreWLAN)
        if let wifi = CWWiFiClient.shared().interface() {
            caps.wifiInterface = wifi.interfaceName
            caps.wifiPoweredOn = wifi.powerOn()
            caps.wifiSupports5GHz = wifi.supportedWLANChannels()?.contains { $0.channelBand == .band5GHz || $0.channelBand == .band6GHz } ?? false
            caps.wifiSSIDConnected = wifi.wlanChannel() != nil
        }
        caps.ethernetActive = interfaces.keys.contains { name in
            name.hasPrefix("en") && name != caps.wifiInterface && hasIPv4(name)
        }
        #else
        caps.wifiInterface = interfaces["en0"] != nil ? "en0" : nil
        caps.wifiPoweredOn = caps.wifiInterface != nil
        caps.wifiSupports5GHz = true
        caps.wifiSSIDConnected = hasIPv4("en0")
        #endif

        #if os(macOS) || os(iOS)
        caps.airDrop = .native
        #endif
        return caps
    }

    private static func interfaceFlags() -> [String: Int32] {
        var result: [String: Int32] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [:] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            result[String(cString: ptr.pointee.ifa_name), default: 0] |= Int32(ptr.pointee.ifa_flags)
        }
        return result
    }

    private static func hasIPv4(_ interface: String) -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).contains {
            String(cString: $0.pointee.ifa_name) == interface && $0.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET)
        }
    }
}
