import AirBridgeCore
import SwiftUI

/// "Check for Updates…" result: up to date, or what's new with an Update button and download progress.
struct UpdateView: View {
    @Environment(Updater.self) private var updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch updater.state {
            case .idle, .checking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Checking for updates…")
                }
                buttons { Button("Cancel") { close() }.keyboardShortcut(.cancelAction) }
            case .upToDate:
                header("You're up to date", "AirBridge \(updater.currentVersion) is the latest version.", symbol: "checkmark.seal.fill", tint: .green)
                buttons { Button("OK") { close() }.keyboardShortcut(.defaultAction) }
            case .available(let update):
                header("AirBridge \(update.version) is available", "You have \(updater.currentVersion).", symbol: "arrow.down.circle.fill", tint: .accentColor)
                if !update.notes.isEmpty {
                    ScrollView {
                        Text((try? AttributedString(markdown: update.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(update.notes))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(height: 220)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 12))
                }
                buttons {
                    Button("Later") { close() }.keyboardShortcut(.cancelAction)
                    Button(update.downloadURL == nil ? "View Release" : "Update and Relaunch") { updater.install(update) }
                        .keyboardShortcut(.defaultAction)
                        .glassButtonStyle(prominent: true)
                }
            case .downloading(let fraction):
                Text("Downloading the update…").font(.headline)
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            case .installing:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Installing. AirBridge will reopen in a moment.")
                }
            case .failed(let message):
                header("Update didn't work", message, symbol: "exclamationmark.triangle.fill", tint: .orange)
                buttons {
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                    Button("Try Again") { updater.check() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func close() {
        updater.showing = false
        dismiss()
    }

    private func header(_ title: String, _ detail: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { Spacer(); content() }.controlSize(.large)
    }
}
