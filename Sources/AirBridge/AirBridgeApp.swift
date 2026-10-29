import AirBridgeCore
import SwiftUI

@main
struct AirBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        WindowGroup("AirBridge", id: "main") {
            ContentView()
                .environment(model)
                .environment(updater)
                .sheet(isPresented: $updater.showing) { UpdateView().environment(updater) }
                .task { updater.checkInBackground() }
                .frame(minWidth: 760, minHeight: 480)
                .modifier(RegisterMainWindowOpener())
                .onOpenURL { model.openLink($0) }
        }
        .handlesExternalEvents(matching: ["airbridge"])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.showing = true
                    updater.check()
                }
            }
            CommandGroup(after: .newItem) {
                Button("Send Files…") { model.chooseAndSend(to: model.selectedPeers) }
                    .keyboardShortcut("o")
                    .disabled(model.selectedPeers.isEmpty)
                Button("Share via Internet Link…") { model.shareViaLink() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Send with AirDrop…") { model.sendWithAirDrop() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }

        MenuBarExtra("AirBridge", systemImage: "arrow.up.arrow.down.circle") {
            MenuBarContent()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When run straight from `swift run` there is no bundle; make it a regular foreground app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click or opening the app again while it keeps running in the menu bar: bring the window back.
    /// SwiftUI doesn't reliably recreate a closed WindowGroup window when a MenuBarExtra is present.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = sender.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            MainWindowOpener.open?()
        }
        sender.activate()
        return false
    }
}

@MainActor enum MainWindowOpener {
    static var open: (() -> Void)?
}

/// Hands the SwiftUI `openWindow` action to the app delegate, which has no environment of its own.
struct RegisterMainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let openWindow = openWindow
            MainWindowOpener.open = { openWindow(id: "main") }
        }
    }
}
