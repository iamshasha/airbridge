import AirBridgeCore
import Observation
import SwiftUI
import UIKit
import UserNotifications

let appGroup = "group.app.airbridge"

/// App-wide state for iPhone and iPad: wraps the engine plus clipboard, notifications and background time.
@MainActor @Observable
final class PhoneModel {
    let node: Node
    var errorMessage: String?
    var pairingCode: PairingCode?
    var sharedLink: SharedLink?
    private(set) var started = false
    /// Inbox items already looked at; the Received tab badge shows the rest.
    var seenInboxCount = 0
    /// Short confirmation banner ("Sent to Mac").
    var toast: Toast?
    /// Latest haptic-worthy event; `RootView` turns it into sensory feedback.
    var feedback: Feedback?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: String
        let tint: Color
    }

    struct Feedback: Equatable {
        enum Kind { case success, error, warning, arrival, crisp }
        let id = UUID()
        let kind: Kind

        var sensory: SensoryFeedback {
            switch kind {
            case .success: return .success
            case .error: return .error
            case .warning: return .warning
            case .arrival: return .impact(flexibility: .soft, intensity: 0.7)
            case .crisp: return .impact(flexibility: .rigid, intensity: 0.8)
            }
        }
    }
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    struct PairingCode: Identifiable {
        let id = UUID()
        let peer: String
        let code: String
    }

    struct SharedLink: Identifiable {
        let id = UUID()
        var link: URL?
        var title: String
        var finished = false
    }

    init() {
        do {
            node = try Node(store: Store(directory: Store.sharedDirectory(appGroup: appGroup)),
                            defaultName: UIDevice.current.name, platform: "ios")
        } catch {
            fatalError("Could not create device identity: \(error)")
        }
        node.onTextReceived = { [weak self] item, toClipboard in
            if toClipboard { UIPasteboard.general.string = item.text }
            self?.signal(.arrival)
            self?.notify(title: "Text from \(item.from)", body: toClipboard ? "Copied to clipboard" : item.text)
        }
        node.onTransferFinished = { [weak self] record in
            guard let self else { return }
            requestNotificationsOnce()
            switch record.state {
            case .done:
                signal(.success)
                if record.direction == .incoming {
                    showToast("Received \(record.title)", symbol: "arrow.down.circle.fill", tint: .green)
                    notify(title: "Received \(record.title)", body: "From \(record.peerName)")
                } else {
                    showToast("Sent to \(record.peerName)", symbol: "checkmark.circle.fill", tint: .green)
                }
            case .failed: signal(.error)
            case .declined:
                signal(.warning)
                showToast("\(record.peerName) declined", symbol: "hand.raised.fill", tint: .orange)
            default: break
            }
            endBackgroundTimeIfIdle()
        }
        node.onUnpairedByPeer = { [weak self] name in
            self?.signal(.warning)
            self?.showToast("\(name) unpaired this \(UIDevice.current.model)", symbol: "link.badge.plus", tint: .orange)
        }
    }

    /// Starts discovery and the listener. Called after onboarding so the system prompts have context.
    func start() {
        guard !started else { return }
        started = true
        node.start()
    }

    // MARK: feedback

    func signal(_ kind: Feedback.Kind) { feedback = Feedback(kind: kind) }

    func showToast(_ text: String, symbol: String, tint: Color) {
        let toast = Toast(text: text, symbol: symbol, tint: tint)
        self.toast = toast
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    /// Asked the first time a transfer happens, when the value (finishing in the background) is obvious.
    private func requestNotificationsOnce() {
        guard !UserDefaults.standard.bool(forKey: "askedNotifications") else { return }
        UserDefaults.standard.set(true, forKey: "askedNotifications")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var hasActiveTransfers: Bool { node.transfers.contains { !$0.state.isFinished } }

    // MARK: lifecycle

    /// iOS suspends apps shortly after they leave the screen; ask for time to finish running transfers.
    func enteredBackground() {
        guard hasActiveTransfers, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AirBridge transfer") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    func becameActive() {
        endBackgroundTimeIfIdle()
        // The listener can be torn down while suspended; bring it back.
        if started, node.listeningPort == nil || node.listenerError != nil { node.republish() }
    }

    private func endBackgroundTimeIfIdle() {
        if !hasActiveTransfers { endBackgroundTime() }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: actions

    /// `scoped` URLs come from the Files picker and need security-scoped access while being read.
    func send(_ urls: [URL], to peers: [Peer], scoped: Bool = false) {
        guard !urls.isEmpty, !peers.isEmpty else { return }
        requestNotificationsOnce()
        let accessed = scoped ? urls.filter { $0.startAccessingSecurityScopedResource() } : []
        Task {
            await withTaskGroup(of: Void.self) { group in
                for peer in peers {
                    group.addTask { @MainActor in
                        do { try await self.node.send(urls, to: peer) } catch {
                            // A decline already gets its own toast and haptic.
                            if case AirBridgeError.declined = error { return }
                            self.report(error, context: "Sending to \(peer.name)")
                        }
                    }
                }
            }
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    func sendText(_ text: String, to peer: Peer) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await node.sendText(trimmed, to: peer)
                signal(.success)
                showToast("Sent to \(peer.name)", symbol: "checkmark.circle.fill", tint: .green)
            } catch { report(error, context: "Sending text to \(peer.name)") }
        }
    }

    func sendClipboard(to peer: Peer) {
        let pb = UIPasteboard.general
        if let url = pb.url, url.isFileURL {
            send([url], to: [peer])
        } else if let text = pb.string ?? pb.url?.absoluteString {
            sendText(text, to: peer)
        } else if let image = pb.image, let data = image.pngData() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard Image.png")
            try? data.write(to: file)
            send([file], to: [peer])
        } else {
            errorMessage = "The clipboard is empty."
        }
    }

    func pair(with peer: Peer) {
        Task {
            do {
                try await node.pair(with: peer) { code in
                    self.pairingCode = PairingCode(peer: peer.name, code: code)
                    self.signal(.crisp)
                }
                pairingCode = nil
                signal(.success)
                showToast("Paired with \(peer.name)", symbol: "checkmark.seal.fill", tint: .green)
            } catch {
                pairingCode = nil
                report(error, context: "Pairing with \(peer.name)")
            }
        }
    }

    func shareViaLink(_ urls: [URL], scoped: Bool) {
        guard node.relayConfigured else {
            errorMessage = "Add a relay URL in Settings › Internet to share links."
            return
        }
        let accessed = scoped ? urls.filter { $0.startAccessingSecurityScopedResource() } : []
        sharedLink = SharedLink(link: nil, title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
        Task {
            defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
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
        Task {
            do { try await node.openLink(url) } catch { report(error, context: "Opening link") }
        }
    }

    func addManualDevice(_ address: String) async -> Peer? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        let host = parts.count == 2 ? String(parts[0]) : trimmed
        let port = parts.count == 2 ? UInt16(parts[1]) ?? 47820 : 47820
        do {
            return try await node.addManualPeer(host: host, port: port)
        } catch {
            report(error, context: "Connecting to \(trimmed)")
            return nil
        }
    }

    func report(_ error: Error, context: String) {
        signal(.error)
        if case AirBridgeError.declined = error {
            errorMessage = "\(context): the other device declined."
        } else {
            errorMessage = "\(context): \(error.localizedDescription)"
        }
    }

    private func notify(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
