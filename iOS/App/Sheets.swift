import AirBridgeCore
import SwiftUI
import UIKit

struct PromptSheet: View {
    @Environment(PhoneModel.self) private var model
    let prompt: Prompt

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: isPairing ? "lock.shield" : "arrow.down.doc")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(prompt.summary)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    switch prompt.kind {
                    case .pairing(let code):
                        Text("Check that \(prompt.peerName) shows the same code.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        CodeView(code: code)
                        Text("Only pair if the codes match. Paired devices can send without asking.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    case .offer(let items, _):
                        let files = items.filter { $0.dir != true }
                        let tops = Set(items.map { $0.path.split(separator: "/").first.map(String.init) ?? "" })
                        let prefix = tops.count == 1 && files.contains(where: { $0.path.contains("/") }) ? tops.first! + "/" : ""
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(files.prefix(6), id: \.i) { item in
                                HStack {
                                    Image(systemName: "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                                    Text(item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.subheadline)
                            }
                            if files.count > 6 {
                                Text("and \(files.count - 6) more").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        Label("End-to-end encrypted", systemImage: "lock.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Unknown device · fingerprint \(prompt.fingerprint.prefix(12))…")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        model.signal(isPairing ? .crisp : .arrival)
                        model.node.respond(to: prompt, accept: true)
                    } label: {
                        Text(isPairing ? "Pair" : "Accept").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(isPairing ? "Don't Pair" : "Decline", role: .cancel) {
                        model.node.respond(to: prompt, accept: false)
                    }
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }

    private var isPairing: Bool { if case .pairing = prompt.kind { return true } else { return false } }
}

struct CodeView: View {
    let code: String
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                    .opacity(shown || reduceMotion ? 1 : 0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.6).delay(Double(index) * 0.05), value: shown)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 36, minHeight: 50)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                if index == 2 { Spacer().frame(width: 8) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
        .onAppear { shown = true }
    }
}

struct PairingCodeSheet: View {
    @Environment(PhoneModel.self) private var model
    let peerName: String
    let code: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield").font(.system(size: 52, weight: .light)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Confirm on \(peerName) that it shows this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                CodeView(code: code)
                ProgressView()
            }
            .padding()
            .navigationTitle("Pairing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.pairingCode = nil } }
            }
        }
        .presentationDetents([.medium])
    }
}

struct LinkShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let share: PhoneModel.SharedLink

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: share.finished ? "checkmark.circle.fill" : "link.circle")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(share.finished ? .green : Color.accentColor)
                    .accessibilityHidden(true)
                if let link = share.link {
                    Text(share.finished ? "The recipient received everything." :
                            "Send this link to the recipient. It works once, from anywhere, and stays end-to-end encrypted. Keep AirBridge open until it's done.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text(link.absoluteString)
                        .font(.footnote.monospaced())
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    if !share.finished {
                        ShareLink(item: link) {
                            Label("Send Link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Label("Waiting for the recipient…", systemImage: "hourglass")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Creating link…")
                }
            }
            .padding()
            .navigationTitle(share.finished ? "Sent \(share.title)" : "Share \(share.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(share.finished ? "Done" : "Hide") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// System share sheet, which includes AirDrop for Apple devices without AirBridge.
struct ActivityView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
