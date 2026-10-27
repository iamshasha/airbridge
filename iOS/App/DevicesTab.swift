import AirBridgeCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct DevicesTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var selection: String?
    @State private var addingDevice = false
    @State private var openingLink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let node = model.node
        let peers = node.peers
        let online = peers.filter { node.isOnline($0) }

        // Side-by-side on iPad and other wide windows; collapses to push navigation on iPhone.
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    if online.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .symbolEffect(.variableColor.iterative.reversing, options: .repeat(.continuous))
                                .accessibilityHidden(true)
                            Text("Looking for devices…").foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    // One stable list: devices dim in place when they go out of range instead of
                    // jumping to another section.
                    ForEach(peers) { peer in
                        NavigationLink(value: peer.id) {
                            PeerRow(peer: peer, trusted: node.isTrusted(peer), online: node.isOnline(peer))
                        }
                    }
                } footer: {
                    if online.isEmpty {
                        Text("Open AirBridge on your other devices. They need Wi-Fi or Bluetooth turned on.")
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
            .animation(reduceMotion ? nil : .snappy, value: peers.map(\.id))
            // A soft tap when a new device shows up nearby.
            .sensoryFeedback(trigger: online.count) { old, new in new > old ? .impact(flexibility: .soft, intensity: 0.5) : nil }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { addingDevice = true } label: { Label("Add by Address", systemImage: "network") }
                        Button { openingLink = true } label: { Label("Receive from Link", systemImage: "link") }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add device or receive from link")
                }
            }
            .sheet(isPresented: $addingDevice) {
                AddDeviceSheet { peer in selection = peer.id }
            }
            .sheet(isPresented: $openingLink) {
                OpenLinkSheet()
            }
        } detail: {
            NavigationStack {
                if let selection {
                    DeviceDetailView(peerID: selection)
                        .id(selection)
                } else {
                    ContentUnavailableView {
                        Label("Choose a Device", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Pick a device on the left to send photos, files or text.")
                    }
                }
            }
        }
    }
}

struct PeerRow: View {
    let peer: Peer
    let trusted: Bool
    let online: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility text sizes, stack the icon above the text so the name gets the full width.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Image(systemName: peer.platformSymbol)
                .font(.title2)
                .foregroundStyle(online ? Color.accentColor : .secondary)
                .frame(minWidth: 36, minHeight: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(peer.name).font(.body)
                    if trusted {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .imageScale(.small)
                            .accessibilityLabel("Trusted")
                    }
                }
                Text(online ? peer.sources.filter { $0 != .trusted }.map(\.label).joined(separator: " · ") : "Not nearby")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(online ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }
}

struct DeviceDetailView: View {
    @Environment(PhoneModel.self) private var model
    let peerID: String
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var composingText = false
    @State private var browsing = false
    @State private var confirmUnpair = false
    @State private var loadingPhotos = false

    var body: some View {
        let node = model.node
        if let peer = node.peer(id: peerID) {
            let trusted = node.isTrusted(peer)
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: peer.platformSymbol)
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(peer.name).font(.title2.bold()).multilineTextAlignment(.center)
                        if trusted {
                            Label("Trusted", systemImage: "checkmark.seal.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.green)
                                .symbolEffect(.bounce, value: trusted)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(node.isOnline(peer) ? peer.sources.map(\.label).joined(separator: " · ") : "Not nearby")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: trusted)
                }

                Section {
                    PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                        ActionLabel(title: "Photos & Videos", symbol: "photo.on.rectangle", busy: loadingPhotos)
                    }
                    Button { importingFiles = true } label: { ActionLabel(title: "Files", symbol: "folder") }
                    Button { model.sendClipboard(to: peer) } label: { ActionLabel(title: "Clipboard", symbol: "doc.on.clipboard") }
                    Button { composingText = true } label: { ActionLabel(title: "Text or Link", symbol: "text.bubble") }
                } header: {
                    Text("Send")
                } footer: {
                    Text(trusted ? "\(peer.name) accepts automatically." : "\(peer.name) will be asked to accept.")
                }

                if trusted, let device = node.trusted[peer.id] {
                    Section {
                        Toggle("Accept Files Automatically", isOn: binding(device, \.autoAccept))
                        Toggle("Allow Browsing My Shared Folder", isOn: binding(device, \.allowBrowse))
                        Toggle("Copy Received Text to Clipboard", isOn: binding(device, \.autoClipboard))
                    } header: {
                        Text("Automation")
                    } footer: {
                        Text("Files from \(device.name) land in Files › On My \(UIDevice.current.model) › AirBridge › Received.")
                    }
                    Section {
                        Button { browsing = true } label: {
                            Label("Browse \(device.name)'s Shared Folder", systemImage: "folder.badge.person.crop")
                        }
                        Button("Unpair", role: .destructive) { confirmUnpair = true }
                    }
                } else {
                    Section {
                        Button { model.pair(with: peer) } label: {
                            Label("Pair with \(peer.name)", systemImage: "lock.shield")
                        }
                    } footer: {
                        Text("Paired devices send and receive without asking and can browse each other's shared folder.")
                    }
                }

                if let fp = peer.fingerprint {
                    Section("Fingerprint") {
                        Text(fp).font(.footnote.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(peer.name)
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.send(urls, to: [peer], scoped: true) }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                loadingPhotos = true
                Task {
                    let urls = await PickedFile.load(items)
                    photoItems = []
                    loadingPhotos = false
                    model.send(urls, to: [peer])
                }
            }
            .sheet(isPresented: $composingText) { ComposeTextSheet(peer: peer) }
            .sheet(isPresented: $browsing) { RemoteBrowser(peer: peer) }
            .confirmationDialog("Unpair \(peer.name)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { node.unpair(peer.id) }
            } message: {
                Text("Automatic transfers with this device stop until you pair again.")
            }
        } else {
            ContentUnavailableView("Device Not Found", systemImage: "questionmark.circle")
        }
    }

    private func binding(_ device: TrustedDevice, _ key: WritableKeyPath<TrustedDevice, Bool>) -> Binding<Bool> {
        Binding(get: { device[keyPath: key] }, set: { value in
            var updated = device
            updated[keyPath: key] = value
            model.node.updateTrusted(updated)
        })
    }
}

struct ActionLabel: View {
    let title: String
    let symbol: String
    var busy = false

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if busy { ProgressView() }
        }
        .contentShape(Rectangle())
    }
}

/// Photos picker items copied to temporary files (originals, not re-encoded).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedFile(url: copy)
        }
    }

    static func load(_ items: [PhotosPickerItem]) async -> [URL] {
        var urls: [URL] = []
        for item in items {
            if let file = try? await item.loadTransferable(type: PickedFile.self) { urls.append(file.url) }
        }
        return urls
    }
}

struct AddDeviceSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onAdded: (Peer) -> Void
    @State private var address = ""
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("100.101.102.103:47820", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connect)
                } footer: {
                    Text("Enter an IP address or hostname, such as a Tailscale address. The default port is 47820.")
                }
            }
            .navigationTitle("Add by Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if connecting { ProgressView() } else {
                        Button("Connect", action: connect).disabled(address.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func connect() {
        guard !address.isEmpty else { return }
        connecting = true
        Task {
            if let peer = await model.addManualDevice(address) {
                dismiss()
                onAdded(peer)
            }
            connecting = false
        }
    }
}

struct OpenLinkSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/r/…", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from Clipboard") { link = UIPasteboard.general.string ?? link }
                } footer: {
                    Text("Paste an AirBridge link someone shared with you.")
                }
            }
            .navigationTitle("Receive from Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Receive") {
                        if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { model.openLink(url) }
                        dismiss()
                    }
                    .disabled(URL(string: link) == nil || link.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ComposeTextSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal)
                .safeAreaInset(edge: .bottom) {
                    Label("End-to-end encrypted", systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
                .navigationTitle("Text to \(peer.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            model.sendText(text, to: peer)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Browse and download from a trusted device's shared folder.
struct RemoteBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let peer: Peer

    var body: some View {
        NavigationStack {
            RemoteFolderView(peer: peer, path: [])
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

struct RemoteFolderView: View {
    @Environment(PhoneModel.self) private var model
    let peer: Peer
    let path: [String]
    @State private var entries: [RemoteEntry] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if let error {
                ContentUnavailableView("Can't Browse", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !loading && entries.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
            ForEach(entries) { entry in
                if entry.dir {
                    NavigationLink {
                        RemoteFolderView(peer: peer, path: path + [entry.name])
                    } label: {
                        Label(entry.name, systemImage: "folder.fill")
                    }
                } else {
                    HStack {
                        Label(entry.name, systemImage: "doc")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .swipeActions {
                        Button("Download") { download(entry) }.tint(.accentColor)
                    }
                    .contextMenu {
                        Button { download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle(path.last ?? "\(peer.name)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            entries = try await model.node.browse(peer, path: path.joined(separator: "/"))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func download(_ entry: RemoteEntry) {
        let remote = (path + [entry.name]).joined(separator: "/")
        Task {
            do { try await model.node.pull([remote], from: peer) } catch { model.report(error, context: "Downloading \(entry.name)") }
        }
    }
}
