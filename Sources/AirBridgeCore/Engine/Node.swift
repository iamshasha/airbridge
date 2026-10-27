import Foundation
import Network
import Observation

/// The AirBridge engine: discovery, trust, listener, and every transfer flow from PROTOCOL.md.
/// State lives on the main actor for the UI; the data path runs in nonisolated tasks.
@MainActor @Observable
public final class Node {
    public private(set) var identity: DeviceIdentity
    public var settings: Settings { didSet { store.save(settings, "settings.json"); refreshLocalInfo() } }
    public private(set) var trusted: [String: TrustedDevice]
    public private(set) var peers: [Peer] = []
    public private(set) var transfers: [TransferRecord] = []
    public private(set) var prompts: [Prompt] = []
    public private(set) var inbox: [ReceivedText] = []
    public private(set) var capabilities = AdapterCapabilities()
    public private(set) var listeningPort: UInt16?
    public private(set) var listenerError: String?

    /// Hooks for the platform layer (clipboard, notifications, reveal in Finder).
    @ObservationIgnored public var onTextReceived: ((ReceivedText, _ toClipboard: Bool) -> Void)?
    @ObservationIgnored public var onTransferFinished: ((TransferRecord) -> Void)?
    /// A request needs a decision (lets apps post an actionable notification while in the background).
    @ObservationIgnored public var onPrompt: ((Prompt) -> Void)?
    /// The named device unpaired this one (directly, or we found out when it refused a trusted request).
    @ObservationIgnored public var onUnpairedByPeer: ((String) -> Void)?

    @ObservationIgnored let store: Store
    @ObservationIgnored nonisolated let local: Locked<SecureChannel.LocalInfo>
    @ObservationIgnored nonisolated let active = Locked<[String: ActiveTransfer]>([:])
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var bonjour: BonjourDiscovery?
    @ObservationIgnored private var bluetooth: BluetoothDiscovery?
    @ObservationIgnored private var peerTable: [String: Peer] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var syncBusy = Set<String>()
    @ObservationIgnored private var deliveringUnpairs = false
    @ObservationIgnored private var bonjourLastSeen: [String: Date] = [:]
    @ObservationIgnored private var latestBonjourIDs = Set<String>()
    private static let bonjourGrace: TimeInterval = 8
    @ObservationIgnored private var lastSyncScan = Date.distantPast
    @ObservationIgnored private let platform: String

    public init(store: Store = Store(directory: Store.defaultDirectory), defaultName: String, platform: String) throws {
        self.store = store
        self.platform = platform
        let identity = try DeviceIdentity.loadOrCreate(at: store.directory.appendingPathComponent("identity.json"))
        self.identity = identity
        let folders = Self.defaultFolders()
        var settings = store.load(Settings.self, "settings.json")
            ?? Settings(deviceName: defaultName, downloadFolder: folders.downloads.path, sharedFolder: folders.shared?.path)
        #if os(iOS)
        // iOS container paths change across installs and updates; always use the current ones.
        settings.downloadFolder = folders.downloads.path
        settings.sharedFolder = folders.shared?.path
        #endif
        self.settings = settings
        trusted = store.load([String: TrustedDevice].self, "trusted.json") ?? [:]
        local = Locked(SecureChannel.LocalInfo(identity: identity, name: defaultName, platform: platform, port: 0))
        refreshLocalInfo()
    }

    /// Where received files land and which folder trusted devices may browse, per platform.
    /// On iOS both live in the app's Documents, which the Files app shows under "On My iPhone › AirBridge".
    public nonisolated static func defaultFolders() -> (downloads: URL, shared: URL?) {
        let fm = FileManager.default
        #if os(iOS)
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let received = docs.appendingPathComponent("Received")
        let shared = docs.appendingPathComponent("Shared")
        try? fm.createDirectory(at: received, withIntermediateDirectories: true)
        try? fm.createDirectory(at: shared, withIntermediateDirectories: true)
        return (received, shared)
        #else
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("AirBridge")
        let publicDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Public")
        return (downloads, fm.fileExists(atPath: publicDir.path) ? publicDir : nil)
        #endif
    }

    private func refreshLocalInfo() {
        local.withLock { $0.name = settings.deviceName; $0.port = listeningPort ?? 0 }
    }

    // MARK: lifecycle

    /// `discovery: false` runs only the listener (tests, headless CLI).
    /// `listen: false` only browses and sends (share extension: the main app owns the listener).
    public func start(discovery: Bool = true, listen: Bool = true) {
        if listen { startListener() }
        if discovery {
            bonjour = BonjourDiscovery { [weak self] found in
                Task { @MainActor in self?.updateBonjour(found) }
            }
            bonjour?.start()
            if settings.bluetoothDiscovery { startBluetooth() }
        }
        rebuildPeers()
        refreshCapabilities()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.tick()
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        listener?.cancel()
        bonjour?.stop()
        bluetooth?.stop()
        listener = nil; bonjour = nil; bluetooth = nil
    }

    public func setBluetooth(_ on: Bool) {
        settings.bluetoothDiscovery = on
        if on { startBluetooth() } else { bluetooth?.stop(); bluetooth = nil; dropSource(.bluetooth) }
    }

    private func startBluetooth() {
        guard bluetooth == nil else { return }
        let local = self.local
        let ble = BluetoothDiscovery(cardProvider: {
            let info = local.current
            return .init(id: info.identity.id, n: info.name, fp: info.identity.fingerprint, pl: info.platform,
                         p: info.port, a: LocalAddresses.current())
        }, onFound: { [weak self] found in
            Task { @MainActor in self?.updateBluetooth(found) }
        })
        ble.onStateChange = { [weak self] _ in Task { @MainActor in self?.refreshCapabilities() } }
        ble.start()
        bluetooth = ble
    }

    public func refreshCapabilities() {
        let state = bluetooth?.state
        let label: String
        switch state {
        case .poweredOn: label = "on"
        case .poweredOff: label = "off"
        case .unauthorized: label = "not allowed"
        case .unsupported: label = "unsupported"
        case .resetting: label = "resetting"
        default: label = settings.bluetoothDiscovery ? "starting" : "disabled in settings"
        }
        capabilities = AdapterCapabilities.probe(bluetoothState: label, bluetoothLEUsable: state == .poweredOn)
    }

    private func tick() {
        for record in transfers where !record.state.isFinished { record.sample() }
        // Bluetooth sightings expire after 3 minutes without a fresh card.
        var changed = false
        for (id, peer) in peerTable where peer.endpoints[.bluetooth] != nil && Date().timeIntervalSince(peer.lastSeen) > 180 {
            peerTable[id]?.endpoints[.bluetooth] = nil
            changed = true
        }
        // Bonjour drop-outs past the grace period.
        for (id, seen) in bonjourLastSeen where !latestBonjourIDs.contains(id) && Date().timeIntervalSince(seen) >= Self.bonjourGrace {
            bonjourLastSeen[id] = nil
            peerTable[id]?.endpoints[.lan] = nil
            peerTable[id]?.endpoints[.peerToPeer] = nil
            changed = true
        }
        if changed { rebuildPeers() }
        if Date().timeIntervalSince(lastSyncScan) > 5 {
            lastSyncScan = Date()
            Task { await deliverPendingUnpairs() }
            runSyncRules()
        }
    }

    // MARK: listener

    private func startListener() {
        listenerError = nil
        let params = Wire.tcpParameters()
        let port = NWEndpoint.Port(rawValue: settings.port) ?? .any
        guard let listener = (try? NWListener(using: params, on: port)) ?? (try? NWListener(using: params)) else {
            listenerError = "Could not open a listening socket"
            return
        }
        let txt = NWTXTRecord(["id": identity.id, "n": settings.deviceName, "fp": identity.fingerprint, "pl": platform, "v": "1"])
        listener.service = NWListener.Service(name: identity.id, type: airBridgeServiceType, domain: nil, txtRecord: txt)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listeningPort = listener.port?.rawValue
                    self.refreshLocalInfo()
                case .failed(let e):
                    self.listenerError = e.localizedDescription
                    // Port taken: fall back to any free port.
                    if self.settings.port != 0, self.listeningPort == nil {
                        listener.cancel()
                        self.settings.port = 0
                        self.startListener()
                    }
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            let wire = Wire(connection)
            Task.detached { await self?.handleIncoming(wire) }
        }
        listener.start(queue: DispatchQueue(label: "airbridge.listener"))
        self.listener = listener
    }

    /// Re-advertise after a rename so the TXT record carries the new name.
    public func republish() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        startListener()
    }

    // MARK: peers

    /// Bonjour results flap (interfaces come and go, the browser restarts). A device that drops out
    /// keeps its last endpoints for `bonjourGrace` seconds, so lists don't flicker.
    private func updateBonjour(_ found: [BonjourDiscovery.Found]) {
        let now = Date()
        var fresh: [String: [DiscoverySource: [PeerEndpoint]]] = [:]
        for f in found where f.id != identity.id {
            fresh[f.id, default: [:]][f.peerToPeer ? .peerToPeer : .lan, default: []].append(.bonjour(f.endpoint))
        }
        for id in peerTable.keys where fresh[id] == nil {
            if let seen = bonjourLastSeen[id], now.timeIntervalSince(seen) < Self.bonjourGrace { continue }
            peerTable[id]?.endpoints[.lan] = nil
            peerTable[id]?.endpoints[.peerToPeer] = nil
        }
        for (id, endpoints) in fresh {
            bonjourLastSeen[id] = now
            peerTable[id]?.endpoints[.lan] = endpoints[.lan]
            peerTable[id]?.endpoints[.peerToPeer] = endpoints[.peerToPeer]
        }
        latestBonjourIDs = Set(fresh.keys)
        for f in found where f.id != identity.id {
            var peer = peerTable[f.id] ?? Peer(id: f.id, name: f.name, platform: f.platform)
            peer.name = f.name
            peer.platform = f.platform
            peer.fingerprint = f.fingerprint ?? peer.fingerprint
            peer.lastSeen = now
            peer.endpoints[.lan] = fresh[f.id]?[.lan]
            peer.endpoints[.peerToPeer] = fresh[f.id]?[.peerToPeer]
            peerTable[f.id] = peer
        }
        rebuildPeers()
    }

    private func updateBluetooth(_ found: BluetoothDiscovery.Found) {
        let card = found.card
        guard card.id != identity.id else { return }
        var peer = peerTable[card.id] ?? Peer(id: card.id, name: card.n, platform: card.pl)
        peer.name = card.n
        peer.platform = card.pl
        peer.fingerprint = card.fp
        peer.rssi = found.rssi
        peer.lastSeen = Date()
        peer.endpoints[.bluetooth] = card.a.map { .host($0, card.p) }
        peerTable[card.id] = peer
        rebuildPeers()
    }

    private func dropSource(_ source: DiscoverySource) {
        for id in peerTable.keys { peerTable[id]?.endpoints[source] = nil }
        rebuildPeers()
    }

    /// Adds a device by address (VPN, routed network, internet). Its identity is learned on first connect.
    public func addManualPeer(host: String, port: UInt16) async throws -> Peer {
        let channel = try await connect([.host(host, port)], fingerprint: nil).channel
        defer { channel.close() }
        let hello = channel.peer
        var peer = peerTable[hello.id] ?? Peer(id: hello.id, name: hello.name, platform: hello.platform)
        peer.name = hello.name
        peer.fingerprint = hello.fingerprint
        peer.endpoints[.manual] = [.host(host, port)]
        peer.lastSeen = Date()
        peerTable[hello.id] = peer
        rebuildPeers()
        return peer
    }

    private func rebuildPeers() {
        // Trusted devices stay listed with their last known address even when discovery is quiet.
        for device in trusted.values {
            var peer = peerTable[device.id] ?? Peer(id: device.id, name: device.name, platform: device.platform)
            peer.fingerprint = device.fingerprint
            if let host = device.lastHost, let port = device.lastPort {
                peer.endpoints[.trusted] = [.host(host, port)]
            }
            peerTable[device.id] = peer
        }
        // Stable order (name, then id) so rows never jump when a device goes on- or offline.
        let sorted = peerTable.values.sorted { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        if sorted != peers { peers = sorted }
    }

    public func isOnline(_ peer: Peer) -> Bool {
        peer.sources.contains { $0 != .trusted }
    }

    public func isTrusted(_ peer: Peer) -> Bool {
        guard let t = trusted[peer.id] else { return false }
        return peer.fingerprint == nil || peer.fingerprint == t.fingerprint
    }

    public func peer(id: String) -> Peer? { peerTable[id] }

    // MARK: trust

    public func updateTrusted(_ device: TrustedDevice) {
        trusted[device.id] = device
        store.save(trusted, "trusted.json")
        rebuildPeers()
    }

    /// Unpairs locally and tells the other device, now or the next time it is reachable.
    public func unpair(_ id: String) {
        if let device = trusted[id] {
            var pending = store.load([String: TrustedDevice].self, "pending-unpairs.json") ?? [:]
            pending[id] = device
            store.save(pending, "pending-unpairs.json")
            Task { await deliverPendingUnpairs() }
        }
        removeTrust(id)
    }

    func removeTrust(_ id: String) {
        trusted[id] = nil
        store.save(trusted, "trusted.json")
        peerTable[id]?.endpoints[.trusted] = nil
        settings.syncRules.removeAll { $0.deviceId == id }
        if peerTable[id].map(isOnline) == false { peerTable[id] = nil }
        rebuildPeers()
    }

    /// Sends queued `unpair` notices to devices that can be reached; keeps the rest for later.
    private func deliverPendingUnpairs() async {
        let pending = store.load([String: TrustedDevice].self, "pending-unpairs.json") ?? [:]
        guard !pending.isEmpty, !deliveringUnpairs else { return }
        deliveringUnpairs = true
        defer { deliveringUnpairs = false }
        var remaining = pending
        for (id, device) in pending {
            var endpoints = peerTable[id]?.orderedEndpoints ?? []
            if let host = device.lastHost, let port = device.lastPort { endpoints.append(.host(host, port)) }
            guard !endpoints.isEmpty,
                  let (channel, _) = try? await connect(endpoints, fingerprint: device.fingerprint) else { continue }
            try? await channel.send(ControlMessage("unpair"))
            _ = try? await channel.receiveControl()
            channel.close()
            remaining[id] = nil
        }
        store.save(remaining, "pending-unpairs.json")
    }

    /// The peer told us (or showed us) it no longer trusts this device.
    private func peerRevokedTrust(_ hello: PeerHello) {
        guard let device = trusted[hello.id], device.fingerprint == hello.fingerprint else { return }
        removeTrust(hello.id)
        onUnpairedByPeer?(device.name)
    }

    private func trust(_ hello: PeerHello, address: (String, UInt16)?) {
        var device = trusted[hello.id] ?? TrustedDevice(id: hello.id, name: hello.name, fingerprint: hello.fingerprint,
                                                        platform: hello.platform, addedAt: Date())
        device.name = hello.name
        device.fingerprint = hello.fingerprint
        if let address { device.lastHost = address.0; device.lastPort = address.1 }
        updateTrusted(device)
    }

    nonisolated func trustedDevice(for hello: PeerHello) async -> TrustedDevice? {
        await MainActor.run {
            guard let t = trusted[hello.id], t.fingerprint == hello.fingerprint else { return nil }
            return t
        }
    }

    /// Remember where a trusted device answered from, so it is reachable without discovery next time.
    private func rememberAddress(of hello: PeerHello, wire: Wire) {
        guard var device = trusted[hello.id], device.fingerprint == hello.fingerprint,
              case .hostPort(let host, _) = wire.connection.currentPath?.remoteEndpoint ?? wire.connection.endpoint,
              hello.port != 0 else { return }
        var h = "\(host)"
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) } // drop IPv6 scope
        guard !h.hasPrefix("fe80"), device.lastHost != h || device.lastPort != hello.port else { return }
        device.lastHost = h
        device.lastPort = hello.port
        updateTrusted(device)
    }

    // MARK: prompts

    private func ask(_ hello: PeerHello, _ kind: Prompt.Kind) async -> Bool {
        await withCheckedContinuation { cont in
            let prompt = Prompt(peerName: hello.name, peerPlatform: hello.platform, fingerprint: hello.fingerprint,
                                kind: kind, continuation: cont)
            prompts.append(prompt)
            onPrompt?(prompt)
        }
    }

    public func prompt(id: UUID) -> Prompt? { prompts.first { $0.id == id } }

    public func respond(to prompt: Prompt, accept: Bool) {
        prompt.resolve(accept)
        prompts.removeAll { $0.id == prompt.id }
    }

    // MARK: connecting

    nonisolated func connect(_ endpoints: [PeerEndpoint], fingerprint: String?) async throws -> (channel: SecureChannel, endpoint: PeerEndpoint) {
        var lastError: Error = AirBridgeError.connectFailed("device is not reachable")
        for endpoint in endpoints {
            do {
                let wire = try await Wire.connect(to: endpoint.nwEndpoint)
                let channel = try await SecureChannel.handshake(wire: wire, local: local.current, isClient: true)
                if let fingerprint, channel.peer.fingerprint != fingerprint {
                    channel.close()
                    throw AirBridgeError.authenticationFailed
                }
                return (channel, endpoint)
            } catch AirBridgeError.authenticationFailed {
                throw AirBridgeError.authenticationFailed
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func connect(to peer: Peer) async throws -> (channel: SecureChannel, endpoint: PeerEndpoint) {
        let result = try await connect(peer.orderedEndpoints, fingerprint: peer.fingerprint ?? trusted[peer.id]?.fingerprint)
        rememberAddress(of: result.channel.peer, wire: result.channel.wire)
        return result
    }

    // MARK: outgoing operations

    /// Sends files and folders (push). `sync` marks auto-upload transfers that overwrite on the receiver.
    @discardableResult
    public func send(_ urls: [URL], to peer: Peer, sync: Bool = false) async throws -> TransferRecord {
        let outgoing = try await Task.detached { try OutgoingItems.expand(urls) }.value
        return try await send(outgoing, to: peer, sync: sync)
    }

    @discardableResult
    func send(_ outgoing: OutgoingItems, to peer: Peer, sync: Bool) async throws -> TransferRecord {
        let transferId = UUID().uuidString
        let tops = Set(outgoing.items.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
        let title = tops.count == 1 ? tops.first! : "\(outgoing.items.filter { $0.dir != true }.count) files"
        let record = TransferRecord(id: transferId, direction: .outgoing, peerName: peer.name, title: title,
                                    total: outgoing.total, sync: sync)
        transfers.insert(record, at: 0)
        do {
            let (control, endpoint) = try await connect(to: peer)
            defer { control.close() }
            try await push(outgoing, transferId: transferId, sync: sync, over: control, endpoint: endpoint, record: record)
        } catch {
            record.finish(Self.failureState(error))
            onTransferFinished?(record)
            throw error
        }
        onTransferFinished?(record)
        return record
    }

    /// Client-side push once the control channel is up. `endpoint == nil` means relay: data rides the control socket.
    private func push(_ outgoing: OutgoingItems, transferId: String, sync: Bool, over control: SecureChannel,
                      endpoint: PeerEndpoint?, record: TransferRecord) async throws {
            var offer = ControlMessage("offer")
            offer.transferId = transferId
            offer.items = outgoing.items
            offer.total = outgoing.total
            offer.sync = sync ? true : nil
            try await control.send(offer)
            record.state = .waitingForAcceptance
            let reply = try await control.receiveControl()
            if reply.t == "notPaired" {
                peerRevokedTrust(control.peer)
                throw AirBridgeError.notTrusted
            }
            guard reply.t == "accept" else {
                throw AirBridgeError.declined(reply.reason ?? "")
            }
            let source = ChunkSource(outgoing)
            defer { source.close() }
            record.activate(counter: source.progress)
            if let endpoint, let n = reply.streams, n > 0 {
                try await runClientTransfer(control: control, endpoint: endpoint, transferId: transferId,
                                            streams: min(n, 16), role: .send(source))
            } else {
                try await Self.runStream(control, role: .send(source))
                let done = try await control.receiveControl()
                guard done.t == "complete" else { throw AirBridgeError.protocolViolation(done.reason ?? "transfer failed") }
            }
            record.finish(.done)
    }

    // MARK: internet links (relay)

    public var relayConfigured: Bool { URL(string: settings.relayURL)?.host != nil }

    /// Shares files through a one-time internet link. `onLink` gets the link to hand to the recipient;
    /// the call returns when the recipient has opened it and the transfer finished (or after an hour).
    @discardableResult
    public func shareViaLink(_ urls: [URL], onLink: @escaping @MainActor (URL) -> Void) async throws -> TransferRecord {
        guard let base = URL(string: settings.relayURL), base.host != nil else {
            throw AirBridgeError.connectFailed("Set a relay URL in Settings first")
        }
        let outgoing = try await Task.detached { try OutgoingItems.expand(urls) }.value
        var raw = Data(count: 16)
        raw.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let room = raw.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // The fingerprint travels in the fragment, which browsers never send to the relay.
        onLink(URL(string: "\(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/r/\(room)#\(identity.fingerprint)")!)

        let transferId = UUID().uuidString
        let tops = Set(outgoing.items.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
        let record = TransferRecord(id: transferId, direction: .outgoing, peerName: "Link recipient",
                                    title: tops.count == 1 ? tops.first! : "\(outgoing.items.filter { $0.dir != true }.count) files",
                                    total: outgoing.total, sync: false)
        record.state = .waitingForAcceptance
        transfers.insert(record, at: 0)
        do {
            let wire = try await Wire.connectRelay(Self.relaySocketURL(base: base, room: room, role: "host"), waitForPeer: 3600)
            let control = try await SecureChannel.handshake(wire: wire, local: local.current, isClient: true)
            defer { control.close() }
            try await push(outgoing, transferId: transferId, sync: false, over: control, endpoint: nil, record: record)
        } catch {
            record.finish(Self.failureState(error))
            onTransferFinished?(record)
            throw error
        }
        onTransferFinished?(record)
        return record
    }

    nonisolated static func relaySocketURL(base: URL, room: String, role: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.scheme = base.scheme == "http" ? "ws" : "wss"
        c.path = "/room/\(room)"
        c.queryItems = [URLQueryItem(name: "role", value: role)]
        c.fragment = nil
        return c.url!
    }

    /// Accepts `https://relay/r/<room>#<fingerprint>` or `airbridge://join/<room>?relay=<host>#<fingerprint>`.
    public static func parseLink(_ link: URL) -> (base: URL, room: String, fingerprint: String?)? {
        let comps = link.pathComponents.filter { $0 != "/" }
        let fingerprint = link.fragment.flatMap { $0.isEmpty ? nil : $0 }
        if link.scheme == "airbridge", link.host == "join", let room = comps.first,
           let relay = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "relay" })?.value,
           let base = URL(string: relay.contains("://") ? relay : "https://\(relay)") {
            return (base, room, fingerprint)
        }
        if link.scheme == "https" || link.scheme == "http", comps.count == 2, comps[0] == "r",
           var c = URLComponents(url: link, resolvingAgainstBaseURL: false) {
            c.path = ""; c.fragment = nil; c.query = nil
            return c.url.map { ($0, comps[1], fingerprint) }
        }
        return nil
    }

    /// Opens a link someone shared: connects through the relay and receives their files.
    public func openLink(_ link: URL) async throws {
        guard let (base, room, fingerprint) = Self.parseLink(link) else {
            throw AirBridgeError.protocolViolation("Not an AirBridge link")
        }
        let wire = try await Wire.connectRelay(Self.relaySocketURL(base: base, room: room, role: "join"), waitForPeer: 30)
        let control = try await SecureChannel.handshake(wire: wire, local: local.current, isClient: false)
        defer { control.close() }
        if let fingerprint, control.peer.fingerprint != fingerprint.lowercased() {
            throw AirBridgeError.authenticationFailed
        }
        let offer = try await control.receiveControl()
        guard offer.t == "offer" else { throw AirBridgeError.protocolViolation("expected an offer") }
        try await receiveOffer(offer, on: control, requested: false, clientEndpoint: nil)
    }

    /// Sends the same files to several devices at once.
    public func send(_ urls: [URL], to targets: [Peer]) async {
        await withTaskGroup(of: Void.self) { group in
            for peer in targets { group.addTask { _ = try? await self.send(urls, to: peer) } }
        }
    }

    public func sendText(_ text: String, to peer: Peer) async throws {
        let (control, _) = try await connect(to: peer)
        defer { control.close() }
        var msg = ControlMessage("text")
        msg.text = text
        try await control.send(msg)
        let reply = try await control.receiveControl()
        guard reply.t == "ok" else { throw AirBridgeError.declined(reply.reason ?? "") }
    }

    /// Pairs with a device. `showCode` receives the 6-digit code to compare with the other screen.
    public func pair(with peer: Peer, showCode: @escaping @MainActor (String) -> Void) async throws {
        let (control, endpoint) = try await connect(peer.orderedEndpoints, fingerprint: peer.fingerprint)
        defer { control.close() }
        showCode(control.sas)
        try await control.send(ControlMessage("pair"))
        let reply = try await control.receiveControl()
        guard reply.t == "pairAccepted" else { throw AirBridgeError.declined(reply.reason ?? "") }
        var address: (String, UInt16)?
        if case .host(let h, let p) = endpoint { address = (h, p) }
        trust(control.peer, address: address)
        rememberAddress(of: control.peer, wire: control.wire)
    }

    public func browse(_ peer: Peer, path: String = "") async throws -> [RemoteEntry] {
        let (control, _) = try await connect(to: peer)
        defer { control.close() }
        var msg = ControlMessage("list")
        msg.path = path
        try await control.send(msg)
        let reply = try await control.receiveControl()
        if reply.t == "notPaired" { peerRevokedTrust(control.peer); throw AirBridgeError.notTrusted }
        guard reply.t == "listing" else { throw AirBridgeError.declined(reply.reason ?? "") }
        return reply.entries ?? []
    }

    /// Downloads paths from a trusted device's shared folder.
    @discardableResult
    public func pull(_ paths: [String], from peer: Peer) async throws -> TransferRecord {
        let (control, endpoint) = try await connect(to: peer)
        defer { control.close() }
        var msg = ControlMessage("pull")
        msg.paths = paths
        try await control.send(msg)
        let offer = try await control.receiveControl()
        if offer.t == "notPaired" { peerRevokedTrust(control.peer); throw AirBridgeError.notTrusted }
        guard offer.t == "offer" else { throw AirBridgeError.declined(offer.reason ?? "") }
        return try await receiveOffer(offer, on: control, requested: true, clientEndpoint: endpoint)
    }

    nonisolated static func failureState(_ error: Error) -> TransferRecord.State {
        if case AirBridgeError.declined = error { return .declined }
        return .failed(error.localizedDescription)
    }

    // MARK: transfer plumbing

    enum Role: @unchecked Sendable {
        case send(ChunkSource)
        case receive(ChunkSink)
    }

    struct ActiveTransfer: @unchecked Sendable {
        var fingerprint: String
        var role: Role
    }

    /// Client side of the data phase: open the stream connections and run them.
    nonisolated func runClientTransfer(control: SecureChannel, endpoint: PeerEndpoint, transferId: String,
                                       streams: Int, role: Role) async throws {
        let fingerprint = control.peer.fingerprint
        let opened = Locked<[SecureChannel]>([])
        defer { opened.current.forEach { $0.close() } }
        let streamTasks = (0 ..< streams).map { _ in
            Task.detached { [self] in
                let (channel, _) = try await connect([endpoint], fingerprint: fingerprint)
                opened.withLock { $0.append(channel) }
                var bind = ControlMessage("stream")
                bind.transferId = transferId
                try await channel.send(bind)
                try await Self.runStream(channel, role: role)
            }
        }
        switch role {
        case .send:
            // Streams finish pumping; the receiver confirms on the control connection.
            let confirmation = Task.detached { try await control.receiveControl() }
            var pumpError: Error?
            for task in streamTasks {
                do { try await task.value } catch { pumpError = pumpError ?? error }
            }
            if let pumpError { confirmation.cancel(); control.close(); throw pumpError }
            let done = try await confirmation.value
            guard done.t == "complete" else { throw AirBridgeError.protocolViolation(done.reason ?? "transfer failed") }
        case .receive(let sink):
            for task in streamTasks {
                Task.detached { do { try await task.value } catch { sink.fail(error) } }
            }
            try await sink.waitUntilComplete()
            try sink.finalize()
            var done = ControlMessage("complete")
            done.transferId = transferId
            try await control.send(done)
            try await control.wire.flush()
        }
    }

    /// Runs one bound stream in either direction until the transfer's data is exhausted.
    nonisolated static func runStream(_ channel: SecureChannel, role: Role) async throws {
        switch role {
        case .send(let source):
            while let chunk = source.next() {
                let plain = try source.plaintext(index: chunk.index, offset: chunk.offset, length: chunk.length)
                try await channel.send(plaintext: plain)
                source.progress.withLock { $0 += Int64(chunk.length) }
            }
            try await channel.wire.flush()
        case .receive(let sink):
            while !sink.isComplete {
                let (type, payload) = try await channel.receive()
                guard type == .chunk else { continue }
                try sink.write(payload: payload)
            }
        }
    }

    // MARK: incoming

    nonisolated func handleIncoming(_ wire: Wire) async {
        do {
            try await wire.start()
            let channel = try await SecureChannel.handshake(wire: wire, local: local.current, isClient: false)
            let first = try await channel.receiveControl()
            switch first.t {
            case "stream": try await attachStream(channel, first)
            case "offer": _ = try await receiveOffer(first, on: channel, requested: false, clientEndpoint: nil)
            case "text": try await handleText(first, on: channel)
            case "pair": try await handlePair(on: channel)
            case "list": try await handleList(first, on: channel)
            case "pull": try await handlePull(first, on: channel)
            case "unpair": try await handleUnpair(on: channel)
            default: try await channel.send(.error("unknown request \(first.t)"))
            }
            try? await channel.wire.flush()
            channel.close()
        } catch {
            wire.cancel()
        }
    }

    nonisolated private func attachStream(_ channel: SecureChannel, _ msg: ControlMessage) async throws {
        guard let id = msg.transferId, let transfer = active.withLock({ $0[id] }),
              transfer.fingerprint == channel.peer.fingerprint else {
            throw AirBridgeError.protocolViolation("unknown transfer")
        }
        do {
            try await Self.runStream(channel, role: transfer.role)
            if case .send = transfer.role {
                // Keep the socket open until the client hangs up so buffered bytes are not cut off.
                _ = try? await channel.receive()
            }
        } catch {
            if case .receive(let sink) = transfer.role { sink.fail(error) }
            throw error
        }
    }

    /// Receiver side of an offer, either pushed to us (server) or answering our pull (client).
    @discardableResult
    func receiveOffer(_ offer: ControlMessage, on control: SecureChannel, requested: Bool,
                      clientEndpoint: PeerEndpoint?) async throws -> TransferRecord {
        let hello = control.peer
        guard let transferId = offer.transferId, let items = offer.items else {
            throw AirBridgeError.protocolViolation("malformed offer")
        }
        let total = items.reduce(Int64(0)) { $0 + ($1.dir == true ? 0 : $1.size) }
        let device = trusted[hello.id].flatMap { $0.fingerprint == hello.fingerprint ? $0 : nil }
        let sync = offer.sync == true && device != nil
        if device != nil { rememberAddress(of: hello, wire: control.wire) }
        // An auto-upload from a device we no longer trust: tell it, so it stops syncing and drops the pairing.
        if offer.sync == true && device == nil {
            try await control.send(ControlMessage.notPaired)
            throw AirBridgeError.notTrusted
        }

        var decision: Bool
        var reason = ""
        if requested { decision = true }
        else if settings.receivePolicy == .off { decision = false; reason = "Receiving is turned off" }
        else if let device, device.autoAccept || sync { decision = true }
        else if settings.receivePolicy == .trustedOnly && device == nil { decision = false; reason = "Only trusted devices may send" }
        else { decision = await ask(hello, .offer(items: items, total: total)) }

        guard decision else {
            var decline = ControlMessage("decline")
            decline.transferId = transferId
            decline.reason = reason.isEmpty ? "The recipient declined" : reason
            try await control.send(decline)
            throw AirBridgeError.declined(reason)
        }

        var base = URL(fileURLWithPath: settings.downloadFolder)
        if sync { base.appendPathComponent(Self.safeFolderName(hello.name)) }
        let tops = Set(items.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })
        let title = tops.count == 1 ? tops.first! : "\(items.filter { $0.dir != true }.count) files"
        let record = TransferRecord(id: transferId, direction: .incoming, peerName: hello.name, title: title,
                                    total: total, sync: sync)
        transfers.insert(record, at: 0)

        do {
            let sink = try ChunkSink(items: items, baseDirectory: base, overwrite: sync)
            record.activate(counter: sink.progress)
            // Over the relay every byte already shares one pipe; use the control socket for data.
            let streams = control.wire.isRelay ? 0 : total < 8 << 20 ? 1 : max(1, settings.parallelStreams)
            var accept = ControlMessage("accept")
            accept.transferId = transferId
            accept.streams = streams
            if streams == 0 {
                try await control.send(accept)
                do {
                    try await Self.runStream(control, role: .receive(sink))
                    try sink.finalize()
                } catch { sink.discard(); throw error }
                var done = ControlMessage("complete")
                done.transferId = transferId
                try await control.send(done)
                try await control.wire.flush()
            } else if let clientEndpoint {
                try await control.send(accept)
                do {
                    try await runClientTransfer(control: control, endpoint: clientEndpoint, transferId: transferId,
                                                streams: streams, role: .receive(sink))
                } catch { sink.discard(); throw error }
            } else {
                active.withLock { $0[transferId] = ActiveTransfer(fingerprint: hello.fingerprint, role: .receive(sink)) }
                defer { active.withLock { $0[transferId] = nil } }
                try await control.send(accept)
                // If the sender disappears, the control socket closes; fail instead of waiting forever.
                let watchdog = Task.detached {
                    _ = try? await control.receive()
                    sink.fail(AirBridgeError.connectionClosed)
                }
                defer { watchdog.cancel() }
                do {
                    try await sink.waitUntilComplete()
                    try sink.finalize()
                } catch { sink.discard(); throw error }
                var done = ControlMessage("complete")
                done.transferId = transferId
                try await control.send(done)
            }
            record.savedURLs = sink.finalURLs
            record.finish(.done)
        } catch {
            record.finish(Self.failureState(error))
            onTransferFinished?(record)
            throw error
        }
        onTransferFinished?(record)
        return record
    }

    private func handleText(_ msg: ControlMessage, on control: SecureChannel) async throws {
        let hello = control.peer
        let device = await trustedDevice(for: hello)
        guard settings.receivePolicy != .off, device != nil || settings.receivePolicy == .everyone,
              let text = msg.text, text.utf8.count <= 1 << 20 else {
            return try await control.send(.error("Not accepted"))
        }
        let item = ReceivedText(from: hello.name, text: text)
        inbox.insert(item, at: 0)
        onTextReceived?(item, device?.autoClipboard == true)
        try await control.send(ControlMessage("ok"))
    }

    private func handleUnpair(on control: SecureChannel) async throws {
        peerRevokedTrust(control.peer)
        try await control.send(ControlMessage("ok"))
    }

    private func handlePair(on control: SecureChannel) async throws {
        let hello = control.peer
        guard settings.receivePolicy != .off else {
            var no = ControlMessage("pairDeclined"); no.reason = "Receiving is turned off"
            return try await control.send(no)
        }
        let accepted = await ask(hello, .pairing(code: control.sas))
        if accepted {
            trust(hello, address: nil)
            rememberAddress(of: hello, wire: control.wire)
            try await control.send(ControlMessage("pairAccepted"))
        } else {
            var no = ControlMessage("pairDeclined"); no.reason = "Pairing was declined"
            try await control.send(no)
        }
    }

    /// Resolves a path inside the shared folder, refusing anything that escapes it.
    private func sharedURL(_ relative: String) -> URL? {
        guard let root = settings.sharedFolder else { return nil }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let comps = relative.split(separator: "/").map(String.init)
        guard !comps.contains("..") else { return nil }
        let url = comps.reduce(rootURL) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        return url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") ? url : nil
    }

    private func handleList(_ msg: ControlMessage, on control: SecureChannel) async throws {
        guard let device = await trustedDevice(for: control.peer), device.allowBrowse else {
            return try await control.send(ControlMessage.notPaired)
        }
        guard let dir = sharedURL(msg.path ?? "") else { return try await control.send(.error("No shared folder")) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var reply = ControlMessage("listing")
        reply.entries = contents.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return RemoteEntry(name: url.lastPathComponent, size: Int64(v?.fileSize ?? 0), dir: v?.isDirectory == true)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try await control.send(reply)
    }

    private func handlePull(_ msg: ControlMessage, on control: SecureChannel) async throws {
        let hello = control.peer
        guard let device = await trustedDevice(for: hello), device.allowBrowse else {
            return try await control.send(ControlMessage.notPaired)
        }
        let urls = (msg.paths ?? []).compactMap(sharedURL)
        guard !urls.isEmpty else { return try await control.send(.error("Nothing to send")) }
        let outgoing = try await Task.detached { try OutgoingItems.expand(urls) }.value
        let transferId = UUID().uuidString
        let record = TransferRecord(id: transferId, direction: .outgoing, peerName: hello.name,
                                    title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items",
                                    total: outgoing.total, sync: false)
        transfers.insert(record, at: 0)
        let source = ChunkSource(outgoing)
        active.withLock { $0[transferId] = ActiveTransfer(fingerprint: hello.fingerprint, role: .send(source)) }
        defer { active.withLock { $0[transferId] = nil }; source.close() }
        do {
            var offer = ControlMessage("offer")
            offer.transferId = transferId
            offer.items = outgoing.items
            offer.total = outgoing.total
            try await control.send(offer)
            let reply = try await control.receiveControl()
            guard reply.t == "accept" else { throw AirBridgeError.declined(reply.reason ?? "") }
            record.activate(counter: source.progress)
            let done = try await control.receiveControl()
            guard done.t == "complete" else { throw AirBridgeError.protocolViolation("transfer failed") }
            record.finish(.done)
        } catch {
            record.finish(Self.failureState(error))
        }
        onTransferFinished?(record)
    }

    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Device" : cleaned
    }

    public func deleteText(_ id: UUID) {
        inbox.removeAll { $0.id == id }
    }

    public func clearInbox() {
        inbox.removeAll()
    }

    public func clearFinishedTransfers() {
        transfers.removeAll { $0.state.isFinished }
    }

    // MARK: auto-sync (auto upload)

    public func addSyncRule(folder: URL, for deviceId: String) {
        settings.syncRules.append(SyncRule(deviceId: deviceId, folder: folder.path))
        lastSyncScan = .distantPast
    }

    public func removeSyncRule(_ id: String) {
        settings.syncRules.removeAll { $0.id == id }
        store.remove("sync-\(id).json")
    }

    private func runSyncRules() {
        for rule in settings.syncRules where rule.enabled && !syncBusy.contains(rule.id) {
            guard let device = trusted[rule.deviceId], let peer = peerTable[rule.deviceId],
                  isOnline(peer) || device.lastHost != nil else { continue }
            syncBusy.insert(rule.id)
            let manifestName = "sync-\(rule.id).json"
            let previous = store.load([String: String].self, manifestName) ?? [:]
            Task {
                defer { syncBusy.remove(rule.id) }
                let folder = URL(fileURLWithPath: rule.folder)
                guard let (changes, manifest) = try? await Task.detached(operation: {
                    try Self.scanChanges(folder: folder, previous: previous)
                }).value, !changes.items.isEmpty else { return }
                do {
                    try await send(changes, to: peer, sync: true)
                    store.save(manifest, manifestName)
                } catch {
                    // Device unreachable or busy: retry on the next scan.
                }
            }
        }
    }

    /// Files whose size or modification time changed since the last successful sync.
    nonisolated static func scanChanges(folder: URL, previous: [String: String]) throws -> (OutgoingItems, [String: String]) {
        let all = try OutgoingItems.expand([folder])
        var manifest: [String: String] = [:]
        var changed = OutgoingItems()
        for (item, url) in zip(all.items, all.urls) where item.dir != true {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            let signature = "\(item.size):\(Int(mtime))"
            manifest[item.path] = signature
            if previous[item.path] != signature {
                changed.add(path: item.path, url: url, size: item.size, dir: false)
            }
        }
        return (changed, manifest)
    }
}

extension Store {
    func remove(_ name: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
}
