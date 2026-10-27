import AirBridgeCore
import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Actionable notifications with previews, so AirBridge works while it sits in the menu bar:
/// accept or decline requests, and see what arrived (pictures, video and audio are attached).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var node: Node?

    var available: Bool { Bundle.main.bundleIdentifier != nil }

    func register(node: Node) {
        self.node = node
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "offer", actions: [UNNotificationAction(identifier: "accept", title: "Accept"), decline],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "pair", actions: [UNNotificationAction(identifier: "accept", title: "Pair"),
                                                                 UNNotificationAction(identifier: "decline", title: "Don't Pair", options: [.destructive])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "received", actions: [UNNotificationAction(identifier: "open", title: "Open", options: [.foreground]),
                                                                     UNNotificationAction(identifier: "reveal", title: "Show in Finder", options: [.foreground])],
                                   intentIdentifiers: []),
        ])
    }

    // MARK: posting

    func prompt(_ prompt: Prompt) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = prompt.summary
        switch prompt.kind {
        case .pairing(let code):
            content.body = "Check that \(prompt.peerName) shows \(code.prefix(3)) \(code.suffix(3))."
            content.categoryIdentifier = "pair"
        case .offer(let items, _):
            let files = items.filter { $0.dir != true }.map { ($0.path as NSString).lastPathComponent }
            content.body = files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
            content.categoryIdentifier = "offer"
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["prompt": prompt.id.uuidString]
        post(content, id: prompt.id.uuidString)
        NSApp.requestUserAttention(.criticalRequest)
    }

    func removePrompt(_ id: UUID) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func received(_ record: TransferRecord) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Received \(record.title)"
        content.body = "From \(record.peerName), \(ByteCountFormatter.string(fromByteCount: record.total, countStyle: .file))"
        content.sound = .default
        if let url = record.savedURLs.first {
            content.categoryIdentifier = "received"
            content.userInfo = ["path": url.path]
            if record.savedURLs.count == 1, let attachment = Self.attachment(for: url) { content.attachments = [attachment] }
        }
        post(content, id: record.id)
    }

    func simple(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(content, id: UUID().uuidString)
    }

    /// Notification Center moves attached files into its own store, so attach a copy.
    static func attachment(for url: URL) -> UNNotificationAttachment? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .audio),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 50 << 20 else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "preview", url: copy)
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let promptID = (info["prompt"] as? String).flatMap(UUID.init(uuidString:))
        let path = info["path"] as? String
        await MainActor.run {
            if let promptID, let node, let prompt = node.prompt(id: promptID) {
                switch action {
                case "accept": node.respond(to: prompt, accept: true)
                case "decline": node.respond(to: prompt, accept: false)
                default: NSApp.activate() // clicked the body: answer in the app's sheet
                }
            } else if let path {
                let url = URL(fileURLWithPath: path)
                if action == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
            } else {
                NSApp.activate()
            }
        }
    }
}
