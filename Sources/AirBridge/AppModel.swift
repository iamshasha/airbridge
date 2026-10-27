import AirBridgeCore
import AppKit
import Observation
import UserNotifications

enum SidebarItem: Hashable {
    case device(String)
    case transfers
    case inbox
    case thisMac
}

/// Window-independent app state: wraps the engine and the platform glue (clipboard, notifications, AirDrop).
@MainActor @Observable
final class AppModel {
    let node: Node
    var selection: Set<SidebarItem> = [.transfers]
    var errorMessage: String?
    /// Outgoing pairing in progress: the code to compare with the other screen.
    var pairingCode: (peer: String, code: String)?
    var sharedLink: SharedLink?
    var startupError: String?

    struct SharedLink: Identifiable {
        let id = UUID()
        var link: URL?
        var title: String
        var finished = false
    }

    init() {
        do {
            node = try Node(defaultName: Host.current().localizedName ?? "Mac", platform: "mac")
        } catch {
            fatalError("Could not create device identity: \(error)")
        }
        node.onTextReceived = { [weak self] item, toClipboard in
            if toClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            self?.notify(title: "Text from \(item.from)", body: toClipboard ? "Copied to clipboard" : item.text)
        }
        node.onTransferFinished = { [weak self] record in
            guard record.direction == .incoming || record.state != .done else { return }
            switch record.state {
            case .done: self?.notify(title: "Received \(record.title)", body: "From \(record.peerName)")
            case .failed(let reason): self?.notify(title: "Transfer failed", body: "\(record.title): \(reason)")
            default: break
            }
        }
        node.onUnpairedByPeer = { [weak self] name in
            self?.notify(title: "\(name) unpaired this Mac", body: "Pair again to send automatically.")
        }
        node.start()
        requestNotificationPermission()
    }

    var selectedPeers: [Peer] {
        selection.compactMap { item in
            if case .device(let id) = item { return node.peer(id: id) }
            return nil
        }
    }

    // MARK: actions

    func send(_ urls: [URL], to peers: [Peer]) {
        guard !urls.isEmpty, !peers.isEmpty else { return }
        for peer in peers {
            Task {
                do { try await node.send(urls, to: peer) } catch { report(error, context: "Sending to \(peer.name)") }
            }
        }
        if !selection.contains(.transfers) && peers.count > 1 { selection = [.transfers] }
    }

    func chooseAndSend(to peers: [Peer]) {
        guard let urls = pickFiles(prompt: "Send") else { return }
        send(urls, to: peers)
    }

    func sendText(_ text: String, to peers: [Peer]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for peer in peers {
            Task {
                do { try await node.sendText(trimmed, to: peer) } catch { report(error, context: "Sending text to \(peer.name)") }
            }
        }
    }

    func sendClipboard(to peers: [Peer]) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            send(urls, to: peers)
        } else if let text = pb.string(forType: .string) {
            sendText(text, to: peers)
        }
    }

    func pair(with peer: Peer) {
        Task {
            do {
                try await node.pair(with: peer) { code in self.pairingCode = (peer.name, code) }
                pairingCode = nil
            } catch {
                pairingCode = nil
                report(error, context: "Pairing with \(peer.name)")
            }
        }
    }

    func shareViaLink(_ urls: [URL]? = nil) {
        guard node.relayConfigured else {
            errorMessage = "Set a relay URL in Settings → Internet to share links. See relay/README.md for the free Cloudflare setup."
            return
        }
        guard let urls = urls ?? pickFiles(prompt: "Create Link") else { return }
        sharedLink = SharedLink(link: nil, title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
        Task {
            do {
                try await node.shareViaLink(urls) { link in self.sharedLink?.link = link }
                sharedLink?.finished = true
            } catch {
                sharedLink = nil
                report(error, context: "Link transfer")
            }
        }
    }

    func openLink(_ url: URL) {
        selection = [.transfers]
        Task {
            do { try await node.openLink(url) } catch { report(error, context: "Opening link") }
        }
    }

    /// Hands files to the system AirDrop service, for Apple devices that don't run AirBridge.
    func sendWithAirDrop(_ urls: [URL]? = nil) {
        guard let urls = urls ?? pickFiles(prompt: "AirDrop"), !urls.isEmpty else { return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            errorMessage = "AirDrop is not available on this Mac. Turn on Wi-Fi and Bluetooth, then try again."
            return
        }
        service.perform(withItems: urls)
    }

    func addManualDevice(_ address: String) {
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: ":")
        let host: String
        let port: UInt16
        if parts.count == 2, let p = UInt16(parts[1]) {
            host = String(parts[0]); port = p
        } else {
            host = address.trimmingCharacters(in: .whitespaces); port = 47820
        }
        Task {
            do {
                let peer = try await node.addManualPeer(host: host, port: port)
                selection = [.device(peer.id)]
            } catch { report(error, context: "Connecting to \(address)") }
        }
    }

    func pickFiles(prompt: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func pickFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func report(_ error: Error, context: String) {
        if case AirBridgeError.declined = error {
            errorMessage = "\(context): the other device declined."
        } else {
            errorMessage = "\(context): \(error.localizedDescription)"
        }
    }

    // MARK: notifications

    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
