import AirBridgeCore
import QuickLook
import SwiftUI

struct TransfersTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var picking: PickPurpose?
    @State private var airDropItems: AirDropItems?
    @State private var preview: URL?

    enum PickPurpose { case link, airDrop }

    struct AirDropItems: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        let transfers = model.node.transfers
        NavigationStack {
            List {
                ForEach(transfers) { record in
                    TransferRow(record: record, onOpen: { preview = $0 })
                }
            }
            .overlay {
                if transfers.isEmpty {
                    ContentUnavailableView {
                        Label("No Transfers", systemImage: "arrow.up.arrow.down")
                    } description: {
                        Text("Choose a device to send photos or files, or share a link to send over the internet.")
                    }
                }
            }
            .navigationTitle("Transfers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { picking = .link } label: { Label("Share via Internet Link", systemImage: "link") }
                        Button { picking = .airDrop } label: { Label("Send with AirDrop", systemImage: "airplayaudio") }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
                ToolbarItem(placement: .topBarLeading) {
                    if transfers.contains(where: { $0.state.isFinished }) {
                        Button("Clear") { model.node.clearFinishedTransfers() }
                    }
                }
            }
            .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                          allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                switch picking {
                case .link: model.shareViaLink(urls, scoped: true)
                case .airDrop: airDropItems = AirDropItems(urls: urls)
                case nil: break
                }
            }
            .sheet(item: $airDropItems) { items in
                ActivityView(urls: items.urls).ignoresSafeArea()
            }
            .quickLookPreview($preview)
        }
    }
}

/// Own view so each row observes only its own record's progress.
struct TransferRow: View {
    @Environment(PhoneModel.self) private var model
    let record: TransferRecord
    var onOpen: (URL) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: record.state == .done)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.body.weight(.medium)).lineLimit(1)
                if record.state == .active {
                    ProgressView(value: record.fraction)
                        .animation(.smooth(duration: 0.25), value: record.fraction)
                        .transition(.opacity)
                }
                (Text(Image(systemName: "lock.fill")) + Text(" ") + Text(subtitle))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("End-to-end encrypted. \(subtitle)")
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: record.state)
        .contentShape(Rectangle())
        .onTapGesture { if let first = openableURL { onOpen(first) } }
        .swipeActions {
            if !record.savedURLs.isEmpty {
                ShareLink(items: record.savedURLs) { Label("Share", systemImage: "square.and.arrow.up") }
                    .tint(.accentColor)
            }
        }
        .contextMenu {
            if !record.savedURLs.isEmpty {
                ShareLink(items: record.savedURLs) { Label("Share or Save…", systemImage: "square.and.arrow.up") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(openableURL != nil ? "Opens a preview" : "")
    }

    private var symbol: String {
        switch record.state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .declined: return "hand.raised.circle.fill"
        default: return record.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        }
    }

    private var tint: Color {
        switch record.state {
        case .done: return .green
        case .failed: return .red
        case .declined: return .orange
        default: return record.direction == .incoming ? .green : .accentColor
        }
    }

    /// Single received files can be previewed; folders are browsed in the Files app.
    private var openableURL: URL? {
        guard record.state == .done, record.savedURLs.count == 1 else { return nil }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: record.savedURLs[0].path, isDirectory: &isDir)
        return isDir.boolValue ? nil : record.savedURLs[0]
    }

    private var subtitle: String {
        let who = "\(record.direction == .outgoing ? "To" : "From") \(record.peerName)"
        let size = ByteCountFormatter.string(fromByteCount: record.total, countStyle: .file)
        switch record.state {
        case .connecting: return "\(who) · Connecting…"
        case .waitingForAcceptance:
            return record.peerName == "Link recipient" ? "Waiting for the link to be opened…" : "\(who) · Waiting for acceptance…"
        case .active:
            return "\(who) · \(Int(record.fraction * 100))% · \(model.node.settings.speedUnit.format(record.bytesPerSecond))"
        case .done:
            return "\(who) · \(size) · \(model.node.settings.speedUnit.format(record.averageBytesPerSecond))"
        case .failed(let reason): return "\(who) · Failed: \(reason)"
        case .declined: return "\(who) · Declined"
        }
    }
}

struct ReceivedTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var confirmClear = false

    private func delete(_ item: ReceivedText) {
        model.node.deleteText(item.id)
        model.signal(.crisp)
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        model.signal(.crisp)
        model.showToast("Copied", symbol: "doc.on.doc.fill", tint: .accentColor)
    }

    var body: some View {
        let inbox = model.node.inbox
        NavigationStack {
            List(inbox) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.from).font(.headline)
                        Spacer()
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("End-to-end encrypted")
                        Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.text).textSelection(.enabled)
                    if let url = URL(string: item.text.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true {
                        Link(destination: url) { Label("Open Link", systemImage: "safari") }
                            .font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .leading) {
                    Button { copy(item.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .tint(.accentColor)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu {
                    Button { copy(item.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: item.text)
                    Divider()
                    Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .overlay {
                if inbox.isEmpty {
                    ContentUnavailableView("Nothing Received", systemImage: "text.bubble",
                                           description: Text("Text, links and clipboard contents sent to this \(UIDevice.current.model) appear here."))
                }
            }
            .navigationTitle("Received")
            .animation(.snappy, value: inbox.map(\.id))
            .toolbar {
                if !inbox.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear All", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .confirmationDialog("Delete all received text?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    model.node.clearInbox()
                    model.signal(.crisp)
                }
            } message: {
                Text("This only removes them from this \(UIDevice.current.model).")
            }
        }
    }
}

struct SettingsTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var name = ""
    @State private var relay = ""
    @State private var confirmUnpair: TrustedDevice?

    var body: some View {
        let node = model.node
        let devices = node.trusted.values.sorted { $0.name < $1.name }
        NavigationStack {
            Form {
                Section {
                    TextField("Device Name", text: $name)
                        .textContentType(.name)
                        .submitLabel(.done)
                        .onSubmit(rename)
                    Picker("Receive From", selection: Binding(get: { node.settings.receivePolicy },
                                                              set: { node.settings.receivePolicy = $0 })) {
                        Text("Everyone").tag(ReceivePolicy.everyone)
                        Text("Trusted Devices Only").tag(ReceivePolicy.trustedOnly)
                        Text("Off").tag(ReceivePolicy.off)
                    }
                } header: {
                    Text("This \(UIDevice.current.model)")
                } footer: {
                    Text("Unknown devices are always asked before they can send.")
                }

                Section {
                    Toggle("Find Devices over Bluetooth", isOn: Binding(get: { node.settings.bluetoothDiscovery },
                                                                       set: { node.setBluetooth($0) }))
                    Stepper("Parallel Streams: \(node.settings.parallelStreams)",
                            value: Binding(get: { node.settings.parallelStreams }, set: { node.settings.parallelStreams = $0 }),
                            in: 1 ... 8)
                    Picker("Show Speeds In", selection: Binding(get: { node.settings.speedUnit }, set: { node.settings.speedUnit = $0 })) {
                        Text("MB/s").tag(SpeedUnit.bytes)
                        Text("Mbps").tag(SpeedUnit.bits)
                    }
                } header: {
                    Text("Discovery & Speed")
                }

                Section {
                    TextField("https://airbridge-relay.you.workers.dev", text: $relay)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { node.settings.relayURL = relay.trimmingCharacters(in: .whitespacesAndNewlines) }
                } header: {
                    Text("Internet Links")
                } footer: {
                    Text("The relay used to share links over the internet. It only forwards encrypted data. Use the same URL as on your Mac.")
                }

                Section("Trusted Devices") {
                    if devices.isEmpty {
                        Text("Pair with a device from its page to trust it.").foregroundStyle(.secondary)
                    }
                    ForEach(devices) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("Paired \(device.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Unpair", role: .destructive) { confirmUnpair = device }
                        }
                    }
                }

                Section {
                    LabeledContent("Listening Port", value: node.listeningPort.map(String.init) ?? "Starting…")
                    ForEach(node.capabilities.summary, id: \.0) { row in
                        LabeledContent {
                            Text(row.1)
                        } label: {
                            Label {
                                Text(row.0)
                            } icon: {
                                Image(systemName: row.2 ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(row.2 ? .green : .secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fingerprint")
                        Text(node.identity.fingerprint).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Network")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                name = node.settings.deviceName
                relay = node.settings.relayURL
                node.refreshCapabilities()
            }
            .onDisappear {
                rename()
                node.settings.relayURL = relay.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .confirmationDialog("Unpair \(confirmUnpair?.name ?? "")?", isPresented: Binding(get: { confirmUnpair != nil },
                                                                                              set: { if !$0 { confirmUnpair = nil } }),
                                titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { if let d = confirmUnpair { node.unpair(d.id) } }
            }
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != model.node.settings.deviceName else { return }
        model.node.settings.deviceName = trimmed
        model.node.republish()
    }
}
