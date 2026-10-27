import AirBridgeCore
import QuickLook
import SwiftUI

@main
struct AirBridgePhoneApp: App {
    @State private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

enum AppTab: Hashable { case devices, transfers, received, settings }

struct RootView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarded") private var onboarded = false
    @State private var tab: AppTab = .devices

    var body: some View {
        @Bindable var model = model
        let node = model.node
        let activeCount = node.transfers.filter { !$0.state.isFinished }.count
        TabView(selection: $tab) {
            Tab("Devices", systemImage: "dot.radiowaves.left.and.right", value: AppTab.devices) {
                DevicesTab()
            }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: AppTab.transfers) {
                TransfersTab()
            }
            .badge(activeCount)
            Tab("Received", systemImage: "text.bubble", value: AppTab.received) {
                ReceivedTab()
            }
            .badge(max(0, node.inbox.count - model.seenInboxCount))
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTab()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .top) { ToastView(toast: model.toast) }
        .quickLookPreview($model.previewURL)
        .modifier(RootPresentations(onboarded: $onboarded))
        // Unread badge: everything counts as seen while the Received tab is showing.
        .onChange(of: tab) { _, new in if new == .received { model.seenInboxCount = node.inbox.count } }
        .onChange(of: node.inbox.count) { _, count in
            model.seenInboxCount = tab == .received ? count : min(model.seenInboxCount, count)
        }
        .onOpenURL { url in
            tab = .transfers
            model.openLink(url)
        }
        .onAppear { if onboarded { model.start() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.enteredBackground()
            case .active: model.becameActive()
            default: break
            }
        }
    }
}

/// App-wide sheets, alerts and haptics, kept apart from `RootView` so its body stays easy to type-check.
struct RootPresentations: ViewModifier {
    @Environment(PhoneModel.self) private var model
    @Binding var onboarded: Bool

    func body(content: Content) -> some View {
        @Bindable var model = model
        let node = model.node
        content
            .sensoryFeedback(trigger: model.feedback) { _, new in new?.sensory }
            // An incoming request deserves a firmer tap as its sheet rises.
            .sensoryFeedback(trigger: node.prompts.count) { old, new in new > old ? .impact(weight: .medium) : nil }
            .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
                OnboardingView {
                    onboarded = true
                    model.start()
                }
            }
            .sheet(item: Binding(get: { node.prompts.first }, set: { _ in })) { prompt in
                PromptSheet(prompt: prompt)
            }
            .sheet(item: $model.pairingCode) { pairing in
                PairingCodeSheet(peerName: pairing.peer, code: pairing.code)
            }
            .sheet(item: $model.sharedLink) { link in
                LinkShareSheet(share: link)
            }
            .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                                set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}

struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("AirBridge")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 18) {
                feature("wifi", "Find devices nearby",
                        "AirBridge looks for your Macs, PCs, iPhones and iPads on Wi-Fi and Bluetooth.")
                feature("lock.shield", "Private by design",
                        "Every transfer is end-to-end encrypted. Pair a device once to trust it.")
                feature("bolt", "As fast as your network",
                        "Files go straight between devices, or over the internet with a link.")
            }
            .padding(.horizontal)
            Spacer()
            Text("Next, iOS asks to let AirBridge find devices on your local network and use Bluetooth. Both are needed to see devices nearby.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(action: onContinue) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
        .padding(.vertical)
        .frame(maxWidth: 520)
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Confirmation banner that drops in from the top and fades away.
struct ToastView: View {
    let toast: PhoneModel.Toast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast {
                Label {
                    Text(toast.text).font(.subheadline.weight(.semibold)).lineLimit(1)
                } icon: {
                    Image(systemName: toast.symbol)
                        .foregroundStyle(toast.tint)
                        .symbolEffect(.bounce, value: toast.id)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.top, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .accessibilityAddTraits(.isStaticText)
                .onAppear { UIAccessibility.post(notification: .announcement, argument: toast.text) }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.75), value: toast)
        .allowsHitTesting(false)
    }
}
