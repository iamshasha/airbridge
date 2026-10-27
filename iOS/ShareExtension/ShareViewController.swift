import AirBridgeCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "AirBridge" in the system share sheet: pick a nearby device and send whatever was shared.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let model = ShareModel(items: items) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        self.model = model
        let host = UIHostingController(rootView: ShareView().environment(model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@MainActor @Observable
final class ShareModel {
    enum Payload {
        case files([URL])
        case text(String)
    }

    let node: Node?
    var payload: Payload?
    var loadError: String?
    var sendingTo: Set<String> = []
    var sentTo: Set<String> = []
    var failure: String?
    private let finish: () -> Void

    init(items: [NSExtensionItem], finish: @escaping () -> Void) {
        self.finish = finish
        // Same app group as the app: same identity, so paired devices accept automatically.
        node = try? Node(store: Store(directory: Store.sharedDirectory(appGroup: "group.app.airbridge")),
                         defaultName: UIDevice.current.name, platform: "ios")
        node?.start(discovery: true, listen: false)
        Task { await load(items) }
    }

    func close() { finish() }

    private func load(_ items: [NSExtensionItem]) async {
        var urls: [URL] = []
        var texts: [String] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
                provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
                provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ||
                provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) &&
                !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) &&
                !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let url = await copyFile(from: provider) { urls.append(url) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                texts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                texts.append(text)
            }
        }
        if !urls.isEmpty {
            payload = .files(urls)
        } else if !texts.isEmpty {
            payload = .text(texts.joined(separator: "\n"))
        } else {
            loadError = "AirBridge can't send this kind of item."
        }
    }

    /// Copies the shared file out of the provider, which deletes its copy when the callback returns.
    private func copyFile(from provider: NSItemProvider) async -> URL? {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        return await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return cont.resume(returning: nil) }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let copy = dir.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    cont.resume(returning: copy)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    var summary: String {
        switch payload {
        case .files(let urls): return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        case .text(let text): return text
        case nil: return loadError ?? "Preparing…"
        }
    }

    func send(to peer: Peer) {
        guard let node, let payload, !sendingTo.contains(peer.id) else { return }
        sendingTo.insert(peer.id)
        Task {
            do {
                switch payload {
                case .files(let urls): try await node.send(urls, to: peer)
                case .text(let text): try await node.sendText(text, to: peer)
                }
                sentTo.insert(peer.id)
            } catch {
                failure = "\(peer.name): \(error.localizedDescription)"
            }
            sendingTo.remove(peer.id)
        }
    }
}

struct ShareView: View {
    @Environment(ShareModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.summary, systemImage: isText ? "text.bubble" : "doc")
                        .lineLimit(3)
                        .foregroundStyle(model.loadError == nil ? .primary : .secondary)
                }
                if let node = model.node {
                    let online = node.peers.filter { node.isOnline($0) }
                    let sending = model.sendingTo
                    let sent = model.sentTo
                    Section {
                        if online.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Looking for devices…").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(online) { peer in
                            Button { model.send(to: peer) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: peer.platformSymbol)
                                        .font(.title2)
                                        .frame(width: 36)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading) {
                                        Text(peer.name).foregroundStyle(.primary)
                                        if node.isTrusted(peer) {
                                            Text("Trusted · accepts automatically").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if sending.contains(peer.id) {
                                        ProgressView()
                                    } else if sent.contains(peer.id) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                            .symbolEffect(.bounce, value: sent.contains(peer.id))
                                            .transition(.scale.combined(with: .opacity))
                                            .accessibilityLabel("Sent")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(model.payload == nil)
                        }
                    } header: {
                        Text("Send to")
                    } footer: {
                        if let failure = model.failure { Text(failure).foregroundStyle(.red) }
                    }
                } else {
                    Text("Open AirBridge once before sharing.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AirBridge")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.sentTo)
            .sensoryFeedback(.success, trigger: model.sentTo.count) { old, new in new > old }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: model.sendingTo.count) { old, new in new > old }
            .sensoryFeedback(.error, trigger: model.failure) { _, new in new != nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.sentTo.isEmpty ? "Cancel" : "Done") { model.close() }
                }
            }
        }
    }

    private var isText: Bool { if case .text = model.payload { return true } else { return false } }
}
