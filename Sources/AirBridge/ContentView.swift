import AirBridgeCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            DetailRouter()
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.shareViaLink() } label: { Label("Share via Link", systemImage: "link") }
                    .help("Send to anyone over the internet with a one-time link")
                Button { model.sendWithAirDrop() } label: { Label("AirDrop", systemImage: "airplayaudio") }
                    .help("Send with the system AirDrop to Apple devices without AirBridge")
            }
        }
        .sheet(item: Binding(get: { model.node.prompts.first }, set: { _ in })) { prompt in
            PromptSheet(prompt: prompt)
        }
        .sheet(isPresented: Binding(get: { model.pairingCode != nil }, set: { if !$0 { model.pairingCode = nil } })) {
            if let pairing = model.pairingCode {
                PairingCodeSheet(peerName: pairing.peer, code: pairing.code)
            }
        }
        .sheet(item: $model.sharedLink) { link in
            LinkShareSheet(share: link)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var addingDevice = false

    var body: some View {
        @Bindable var model = model
        let node = model.node
        let peers = node.peers

        // One section with a stable order: devices dim in place when they go out of range instead of
        // moving between sections, which made rows jump while the sidebar animated.
        List(selection: $model.selection) {
            Section("Devices") {
                if peers.isEmpty {
                    Label("Looking for devices…", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative.reversing)
                        .selectionDisabled()
                }
                ForEach(peers) { peer in
                    PeerRow(peer: peer, trusted: node.isTrusted(peer), online: node.isOnline(peer))
                        .tag(SidebarItem.device(peer.id))
                }
            }
            ActivitySection()
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { addingDevice = true } label: { Label("Add by Address", systemImage: "plus") }
                    .help("Add a device by address (VPN such as Tailscale, or a routed network)")
                    .popover(isPresented: $addingDevice, arrowEdge: .bottom) {
                        AddDevicePopover { address in
                            addingDevice = false
                            model.addManualDevice(address)
                        }
                    }
            }
        }
    }
}

/// Own view so transfer progress and inbox changes only redraw these rows, not the device list.
struct ActivitySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let node = model.node
        Section("Activity") {
            Label("Transfers", systemImage: "arrow.up.arrow.down")
                .badge(node.transfers.filter { !$0.state.isFinished }.count)
                .tag(SidebarItem.transfers)
            Label("Received Text", systemImage: "text.bubble")
                .badge(node.inbox.count)
                .tag(SidebarItem.inbox)
            Label("This Mac", systemImage: "cpu")
                .tag(SidebarItem.thisMac)
        }
    }
}

struct PeerRow: View {
    @Environment(AppModel.self) private var model
    let peer: Peer
    let trusted: Bool
    let online: Bool
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peer.platformSymbol)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(online ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(peer.name).lineLimit(1)
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .imageScale(.small)
                        .opacity(trusted ? 1 : 0)
                        .accessibilityHidden(!trusted)
                        .accessibilityLabel("Trusted")
                }
                Group {
                    if online {
                        HStack(spacing: 4) {
                            ForEach(peer.sources.filter { $0 != .trusted }, id: \.self) { source in
                                Image(systemName: source.symbol).help(source.label)
                            }
                        }
                    } else {
                        Text("Not nearby")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .opacity(online ? 1 : 0.6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Drop highlight as an overlay: toggling listRowBackground changes the row's background
        // configuration and can make the sidebar redraw mid-animation.
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(targeted ? 0.2 : 0))
                .padding(-4)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.send(urls, to: [peer])
            return true
        } isTargeted: { targeted = $0 }
        .sensoryFeedback(.alignment, trigger: targeted) { _, new in new }
        .accessibilityElement(children: .combine)
    }
}

struct AddDevicePopover: View {
    var onAdd: (String) -> Void
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add device by address").font(.headline)
            Text("Use an IP or hostname, e.g. a Tailscale address. Default port is 47820.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("100.101.102.103:47820", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !address.isEmpty { onAdd(address) } }
            HStack {
                Spacer()
                Button("Connect") { onAdd(address) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Detail routing

struct DetailRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let peers = model.selectedPeers
        if peers.count > 1 {
            MultiDeviceView(peers: peers)
        } else if let peer = peers.first {
            DeviceDetailView(peerID: peer.id)
                .id(peer.id)
        } else if model.selection.contains(.inbox) {
            InboxView()
        } else if model.selection.contains(.thisMac) {
            ThisMacView()
        } else {
            TransfersView()
        }
    }
}
