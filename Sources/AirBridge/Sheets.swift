import AirBridgeCore
import AppKit
import SwiftUI

struct PromptSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: Prompt

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text(prompt.summary)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            switch prompt.kind {
            case .pairing(let code):
                Text("Check that \(prompt.peerName) shows the same code:")
                    .foregroundStyle(.secondary)
                CodeView(code: code)
                Text("Only pair if the codes match. Paired devices can send without asking.")
                    .font(.caption).foregroundStyle(.secondary)
            case .offer(let items, _):
                let files = items.filter { $0.dir != true }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files.prefix(6), id: \.i) { item in
                        HStack {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(item.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                    if files.count > 6 {
                        Text("and \(files.count - 6) more…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Text("Unknown device · fingerprint \(prompt.fingerprint.prefix(12))…")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Button(isPairing ? "Don't Pair" : "Decline") { model.node.respond(to: prompt, accept: false) }
                    .keyboardShortcut(.cancelAction)
                Button(isPairing ? "Pair" : "Accept") { model.node.respond(to: prompt, accept: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private var isPairing: Bool { if case .pairing = prompt.kind { return true } else { return false } }
    private var icon: String { isPairing ? "lock.shield" : "arrow.down.doc" }
}

struct CodeView: View {
    let code: String
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 34, height: 46)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                if index == 2 { Spacer().frame(width: 8) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}

struct PairingCodeSheet: View {
    @Environment(AppModel.self) private var model
    let peerName: String
    let code: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 44, weight: .light)).foregroundStyle(.tint)
            Text("Pairing with \(peerName)").font(.title3.weight(.semibold))
            Text("Confirm on \(peerName) that it shows this code:").foregroundStyle(.secondary)
            CodeView(code: code)
            ProgressView().controlSize(.small)
            Button("Cancel") { model.pairingCode = nil }.keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 380)
    }
}

struct LinkShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let share: AppModel.SharedLink
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: share.finished ? "checkmark.circle.fill" : "link.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(share.finished ? .green : Color.accentColor)
            Text(share.finished ? "Sent \(share.title)" : "Share \(share.title)").font(.title3.weight(.semibold))
            if let link = share.link {
                Text(share.finished ? "The recipient received everything." :
                        "Send this link to the recipient. It works once, from anywhere, and stays end-to-end encrypted. Keep AirBridge open until it's done.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(link.absoluteString)
                        .font(.callout.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        copied = true
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                if !share.finished {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the recipient…").foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Creating link…")
            }
            Button(share.finished ? "Done" : "Hide") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 460)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let node = model.node
        let online = node.peers.filter { node.isOnline($0) }
        let active = node.transfers.filter { !$0.state.isFinished }
        if online.isEmpty {
            Text("No devices nearby")
        } else {
            Section("Send clipboard to") {
                ForEach(online) { peer in
                    Button(peer.name) { model.sendClipboard(to: [peer]) }
                }
            }
        }
        if !active.isEmpty {
            Section("Active") {
                ForEach(active) { record in
                    Text("\(record.title) — \(Int(record.fraction * 100))%")
                }
            }
        }
        Divider()
        Button("Share via Link…") { model.shareViaLink() }
        Button("Send with AirDrop…") { model.sendWithAirDrop() }
        Button("Receive from Link in Clipboard") {
            if let s = NSPasteboard.general.string(forType: .string), let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                model.openLink(url)
            }
        }
        Divider()
        Button("Open AirBridge") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
