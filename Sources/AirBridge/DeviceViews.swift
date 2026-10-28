import AirBridgeCore
import SwiftUI

/// Big drop target used on device pages.
struct DropZone: View {
    let title: String
    let subtitle: String
    let onDrop: ([URL]) -> Void
    let onChoose: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.up.doc.on.clipboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            Button("Choose Files…", action: onChoose)
                .controlSize(.large)
                .glassButtonStyle(prominent: targeted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
        .glassSurface(in: RoundedRectangle(cornerRadius: 20), tint: targeted ? Color.accentColor.opacity(0.3) : nil,
                      interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(6)
                .allowsHitTesting(false)
        }
        .scaleEffect(targeted ? 1.01 : 1)
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .sensoryFeedback(.alignment, trigger: targeted) { _, new in new }
    }
}

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let peerID: String
    @State private var text = ""
    @State private var browsing = false

    var body: some View {
        let node = model.node
        if let peer = node.peer(id: peerID) {
            let trusted = node.isTrusted(peer)
            let online = node.isOnline(peer)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(peer, trusted: trusted, online: online)

                    DropZone(title: "Drop files or folders to send",
                             subtitle: trusted ? "\(peer.name) accepts automatically" : "\(peer.name) will be asked to accept",
                             onDrop: { model.send($0, to: [peer]) },
                             onChoose: { model.chooseAndSend(to: [peer]) })

                    GroupBox("Send text or a link") {
                        HStack {
                            TextField("Message, link or note", text: $text, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1 ... 4)
                                .onSubmit(send)
                            Button("Send", action: send).disabled(text.isEmpty)
                            Button("Send Clipboard") { model.sendClipboard(to: [peer]) }
                        }
                        .padding(6)
                    }

                    if trusted, let device = node.trusted[peer.id] {
                        TrustedDeviceSettings(device: device, peer: peer, browsing: $browsing)
                    } else {
                        GroupBox {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "lock.shield").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Trust this device").font(.headline)
                                    Text("Paired devices send and receive without prompts, can sync folders automatically, and can browse your shared folder.")
                                        .font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button("Pair…") { model.pair(with: peer) }
                                    .controlSize(.large)
                                    .glassButtonStyle(prominent: true)
                            }
                            .padding(6)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(peer.name)
            .sheet(isPresented: $browsing) { RemoteBrowser(peer: peer) }
        } else {
            ContentUnavailableView("Device not found", systemImage: "questionmark.circle")
        }
    }

    private func send() {
        guard let peer = model.node.peer(id: peerID) else { return }
        model.sendText(text, to: [peer])
        text = ""
    }

    @ViewBuilder
    private func header(_ peer: Peer, trusted: Bool, online: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: peer.platformSymbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(peer.name).font(.title.weight(.semibold))
                    if trusted {
                        Label("Trusted", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.medium))
                            .glassBadge(.green)
                    }
                }
                HStack(spacing: 12) {
                    if online {
                        ForEach(peer.sources, id: \.self) { source in
                            Label(source.label, systemImage: source.symbol)
                        }
                        if let rssi = peer.rssi, peer.sources.contains(.bluetooth) {
                            Text("\(rssi) dBm")
                        }
                    } else {
                        Label("Not nearby — will try last known address", systemImage: "moon.zzz")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let fp = peer.fingerprint {
                    Text("Fingerprint \(fp.prefix(16))…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct TrustedDeviceSettings: View {
    @Environment(AppModel.self) private var model
    let device: TrustedDevice
    let peer: Peer
    @Binding var browsing: Bool
    @State private var confirmUnpair = false

    var body: some View {
        let node = model.node
        let rules = node.settings.syncRules.filter { $0.deviceId == device.id }
        GroupBox("Automation") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Accept files automatically (auto download)", isOn: binding(\.autoAccept))
                Toggle("Allow browsing and downloading my shared folder", isOn: binding(\.allowBrowse))
                Toggle("Put received text on the clipboard", isOn: binding(\.autoClipboard))
                Divider()
                HStack {
                    Text("Auto-upload folders").font(.headline)
                    Spacer()
                    Button("Add Folder…") {
                        if let folder = model.pickFolder(prompt: "Sync") { node.addSyncRule(folder: folder, for: device.id) }
                    }
                }
                if rules.isEmpty {
                    Text("New and changed files in a synced folder are sent to \(device.name) automatically.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    HStack {
                        Image(systemName: "folder.badge.gearshape")
                        Text(rule.folder).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { node.removeSyncRule(rule.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Stop syncing \(rule.folder)")
                    }
                }
                Divider()
                HStack {
                    Button("Browse \(device.name)'s Shared Folder…") { browsing = true }
                    Spacer()
                    Button("Unpair", role: .destructive) { confirmUnpair = true }
                }
            }
            .padding(6)
        }
        .confirmationDialog("Unpair \(device.name)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { node.unpair(device.id) }
        } message: {
            Text("Automatic transfers and folder sync with this device stop until you pair again.")
        }
    }

    private func binding(_ key: WritableKeyPath<TrustedDevice, Bool>) -> Binding<Bool> {
        Binding(get: { device[keyPath: key] }, set: { value in
            var updated = device
            updated[keyPath: key] = value
            model.node.updateTrusted(updated)
        })
    }
}

struct MultiDeviceView: View {
    @Environment(AppModel.self) private var model
    let peers: [Peer]

    var body: some View {
        VStack(spacing: 20) {
            // Overlapping glass discs melt into one another.
            GlassGroup(spacing: 12) {
                HStack(spacing: -10) {
                    ForEach(peers.prefix(5)) { peer in
                        Image(systemName: peer.platformSymbol)
                            .font(.title)
                            .frame(width: 52, height: 52)
                            .glassSurface(in: Circle())
                    }
                }
            }
            Text("Send to \(peers.count) devices").font(.title2.weight(.semibold))
            Text(peers.map(\.name).formatted(.list(type: .and)))
                .foregroundStyle(.secondary)
            DropZone(title: "Drop files to send to all", subtitle: "Each device receives in parallel",
                     onDrop: { model.send($0, to: peers) },
                     onChoose: { model.chooseAndSend(to: peers) })
            Button("Send Clipboard to All") { model.sendClipboard(to: peers) }
                .glassButtonStyle()
        }
        .padding(32)
        .frame(maxWidth: 640)
    }
}

/// Browse and download from a trusted device's shared folder.
struct RemoteBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    @State private var path: [String] = []
    @State private var entries: [RemoteEntry] = []
    @State private var selection = Set<String>()
    @State private var error: String?
    @State private var loading = true

    private var pathString: String { path.joined(separator: "/") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { path.removeLast() } label: { Image(systemName: "chevron.left") }
                    .disabled(path.isEmpty)
                    .accessibilityLabel("Back")
                Text(path.isEmpty ? "\(peer.name) — Shared" : path.last!).font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            if let error {
                ContentUnavailableView("Can't browse", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                List(entries, selection: $selection) { entry in
                    HStack {
                        Image(systemName: entry.dir ? "folder.fill" : "doc")
                            .foregroundStyle(entry.dir ? Color.accentColor : .secondary)
                        Text(entry.name)
                        Spacer()
                        if !entry.dir {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .tag(entry.name)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if entry.dir { path.append(entry.name) } }
                }
            }
            Divider()
            HStack {
                Text("Double-click a folder to open it").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download \(selection.count > 0 ? "\(selection.count) " : "")Item\(selection.count == 1 ? "" : "s")") {
                    let paths = selection.map { (path + [$0]).joined(separator: "/") }
                    Task {
                        do { try await model.node.pull(paths, from: peer) } catch { model.errorMessage = error.localizedDescription }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 440)
        .task(id: pathString) {
            loading = true
            selection = []
            do {
                entries = try await model.node.browse(peer, path: pathString)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
