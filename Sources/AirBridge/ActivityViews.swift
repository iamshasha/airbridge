import AirBridgeCore
import AppKit
import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let transfers = model.node.transfers
        Group {
            if transfers.isEmpty {
                ContentUnavailableView {
                    Label("No transfers yet", systemImage: "arrow.up.arrow.down")
                } description: {
                    Text("Drop files on a device in the sidebar, or share a link to send over the internet.")
                }
            } else {
                List {
                    ForEach(transfers) { record in
                        TransferRow(record: record)
                    }
                }
            }
        }
        .navigationTitle("Transfers")
        .toolbar {
            ToolbarItem {
                Button("Clear Finished") { model.node.clearFinishedTransfers() }
                    .disabled(!transfers.contains { $0.state.isFinished })
            }
        }
    }
}

/// Separate view so each row observes only its own record's progress.
struct TransferRow: View {
    let record: TransferRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(record.direction == .outgoing ? Color.accentColor : .green)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.title).fontWeight(.medium).lineLimit(1)
                    if record.sync {
                        Text("SYNC").font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Text(statusText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if record.state == .active {
                    ProgressView(value: record.fraction)
                }
                Text("\(record.direction == .outgoing ? "To" : "From") \(record.peerName) · \(ByteCountFormatter.string(fromByteCount: record.total, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if record.state == .done, !record.savedURLs.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(record.savedURLs)
                } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch record.state {
        case .connecting: return "Connecting…"
        case .waitingForAcceptance: return record.peerName == "Link recipient" ? "Waiting for link to open…" : "Waiting for acceptance…"
        case .active:
            let rate = ByteCountFormatter.string(fromByteCount: Int64(record.bytesPerSecond), countStyle: .file)
            return "\(Int(record.fraction * 100))% · \(rate)/s"
        case .done:
            let rate = ByteCountFormatter.string(fromByteCount: Int64(record.averageBytesPerSecond), countStyle: .file)
            return "Done · \(rate)/s"
        case .failed(let reason): return "Failed: \(reason)"
        case .declined: return "Declined"
        }
    }
}

struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inbox = model.node.inbox
        Group {
            if inbox.isEmpty {
                ContentUnavailableView("No text received", systemImage: "text.bubble",
                                       description: Text("Text, links and clipboard contents sent to this Mac appear here."))
            } else {
                List(inbox) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.from).font(.headline)
                            Spacer()
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                .help("End-to-end encrypted")
                            Text(item.date, style: .time).foregroundStyle(.secondary).font(.caption)
                        }
                        Text(item.text).textSelection(.enabled)
                        HStack {
                            Button("Delete", role: .destructive) { model.node.deleteText(item.id) }
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.text, forType: .string)
                            }
                            if let url = URL(string: item.text.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true {
                                Button("Open Link") { NSWorkspace.shared.open(url) }
                            }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Received Text")
        .toolbar {
            ToolbarItem {
                Button("Clear All") { model.node.clearInbox() }.disabled(inbox.isEmpty)
            }
        }
    }
}

struct ThisMacView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let node = model.node
        let caps = node.capabilities
        Form {
            Section("Identity") {
                LabeledContent("Name", value: node.settings.deviceName)
                LabeledContent("Fingerprint") {
                    Text(node.identity.fingerprint).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Listening port", value: node.listeningPort.map(String.init) ?? "starting…")
                LabeledContent("Addresses", value: LocalAddressList.current.joined(separator: ", "))
                if let err = node.listenerError { Text(err).foregroundStyle(.red) }
            }
            Section {
                ForEach(caps.summary, id: \.0) { row in
                    LabeledContent {
                        Text(row.1).foregroundStyle(.secondary)
                    } label: {
                        Label {
                            Text(row.0)
                        } icon: {
                            Image(systemName: row.2 ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(row.2 ? .green : .secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Adapters")
                    Spacer()
                    Button("Refresh") { node.refreshCapabilities() }.controlSize(.small)
                }
            } footer: {
                Text("AirBridge uses LAN and peer-to-peer Wi-Fi for data, Bluetooth LE to find devices when multicast is blocked, and system AirDrop for Apple devices that don't run AirBridge.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("This Mac")
        .task { node.refreshCapabilities() }
    }
}

enum LocalAddressList {
    static var current: [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  Int32(ptr.pointee.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}
