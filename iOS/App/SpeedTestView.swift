import AirBridgeCore
import SwiftUI
import UIKit

/// Measures upload and download speed with one device. The ring is the brand ring every platform uses
/// for progress; the number in it is the live speed in the chosen unit.
struct SpeedTestView: View {
    @Environment(PhoneModel.self) private var model
        let peer: Peer

    @State private var progress: SpeedTestProgress?
    @State private var result: SpeedTestResult?
    @State private var error: String?
    @State private var running = false

    var body: some View {
        @Bindable var node = model.node
        let unit = node.settings.speedUnit
        VStack(spacing: 22) {
            Text("Speed with \(peer.name)").font(.title2.weight(.semibold)).multilineTextAlignment(.center)

            ZStack {
                Circle().stroke(.quaternary, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: ringFraction)
                    .stroke(LinearGradient(colors: [Color(red: 0.10, green: 0.48, blue: 1), Color(red: 0.18, green: 0.82, blue: 0.95)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: ringFraction)
                VStack(spacing: 4) {
                    Text(centerValue(unit))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.snappy, value: centerValue(unit))
                    Text(phaseLabel).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)
            .accessibilityElement(children: .combine)

            HStack(spacing: 28) {
                resultColumn("Upload", symbol: "arrow.up", value: result?.upload, unit: unit)
                resultColumn("Download", symbol: "arrow.down", value: result?.download, unit: unit)
            }

            Picker("Unit", selection: $node.settings.speedUnit) {
                ForEach(SpeedUnit.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Button(action: start) {
                Text(result == nil && !running ? "Start" : "Test Again").frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(running)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .task { start() }
        // A tick as the test switches direction, a success tap when it's done.
        .sensoryFeedback(.selection, trigger: progress?.phase)
        .sensoryFeedback(.success, trigger: result)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var ringFraction: Double {
        guard let progress else { return result == nil ? 0 : 1 }
        // Upload fills the first half of the ring, download the second.
        return (progress.phase == .upload ? 0 : 0.5) + progress.fraction / 2
    }

    private var phaseLabel: String {
        if running, let progress { return progress.phase == .upload ? "Uploading" : "Downloading" }
        if running { return "Connecting" }
        return result == nil ? "Ready" : "Average of both"
    }

    private func centerValue(_ unit: SpeedUnit) -> String {
        if running, let progress, progress.bytesPerSecond > 0 { return unit.format(progress.bytesPerSecond) }
        if let result { return unit.format((result.upload + result.download) / 2) }
        return "–"
    }

    private func resultColumn(_ title: String, symbol: String, value: Double?, unit: SpeedUnit) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value.map(unit.format) ?? "–").font(.title3.weight(.medium).monospacedDigit())
        }
        .frame(minWidth: 120)
    }

    private func start() {
        guard !running else { return }
        running = true
        error = nil
        result = nil
        progress = nil
        Task {
            do {
                result = try await model.node.speedTest(with: peer) { progress = $0 }
            } catch {
                self.error = error.localizedDescription
                model.signal(.error)
            }
            progress = nil
            running = false
        }
    }
}

