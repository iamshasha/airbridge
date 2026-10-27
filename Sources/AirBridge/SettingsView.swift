import AirBridgeCore
import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            InternetSettings().tabItem { Label("Internet", systemImage: "globe") }
            DevicesSettings().tabItem { Label("Devices", systemImage: "checkmark.seal") }
        }
        .frame(width: 560, height: 420)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        let node = model.node
        Form {
            Section {
                TextField("Device name", text: $name)
                    .onSubmit { rename() }
                Picker("Receive from", selection: Binding(get: { node.settings.receivePolicy },
                                                          set: { node.settings.receivePolicy = $0 })) {
                    ForEach(ReceivePolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("Folders") {
                folderRow("Save received files to", path: node.settings.downloadFolder) { node.settings.downloadFolder = $0 }
                folderRow("Shared folder (trusted devices can browse)", path: node.settings.sharedFolder ?? "Not shared") {
                    node.settings.sharedFolder = $0
                }
            }
            Section("Performance & discovery") {
                Stepper("Parallel streams for large files: \(node.settings.parallelStreams)",
                        value: Binding(get: { node.settings.parallelStreams }, set: { node.settings.parallelStreams = $0 }),
                        in: 1 ... 8)
                Toggle("Discover devices over Bluetooth LE", isOn: Binding(get: { node.settings.bluetoothDiscovery },
                                                                          set: { node.setBluetooth($0) }))
            }
        }
        .formStyle(.grouped)
        .onAppear { name = node.settings.deviceName }
        .onDisappear { rename() }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != model.node.settings.deviceName else { return }
        model.node.settings.deviceName = trimmed
        model.node.republish()
    }

    private func folderRow(_ title: String, path: String, set: @escaping (String) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Change…") { if let url = model.pickFolder(prompt: "Choose") { set(url.path) } }
            }
        }
    }
}

struct InternetSettings: View {
    @Environment(AppModel.self) private var model
    @State private var relay = ""

    var body: some View {
        Form {
            Section {
                TextField("Relay URL", text: $relay, prompt: Text("https://airbridge-relay.you.workers.dev"))
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button("Save", action: save).disabled(relay == model.node.settings.relayURL)
                }
            } header: {
                Text("Internet links")
            } footer: {
                Text("Links let anyone receive your files over the internet. Deploy the free relay in the project's relay/ folder to Cloudflare Workers (npx wrangler deploy) and paste its URL here. The relay only forwards encrypted bytes.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("For your own devices across networks, install Tailscale (free) on each and use **Add by Address** with the device's Tailscale IP. Transfers then run peer-to-peer over WireGuard at full speed.")
                Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
            } header: {
                Text("Always-on remote access")
            }
        }
        .formStyle(.grouped)
        .onAppear { relay = model.node.settings.relayURL }
    }

    private func save() {
        model.node.settings.relayURL = relay.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DevicesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let devices = model.node.trusted.values.sorted { $0.name < $1.name }
        Group {
            if devices.isEmpty {
                ContentUnavailableView("No trusted devices", systemImage: "checkmark.seal",
                                       description: Text("Pair with a device from its page to trust it."))
            } else {
                List(devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name).font(.headline)
                            Text("\(device.fingerprint.prefix(16))… · paired \(device.addedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unpair", role: .destructive) { model.node.unpair(device.id) }
                    }
                }
            }
        }
        .padding()
    }
}
