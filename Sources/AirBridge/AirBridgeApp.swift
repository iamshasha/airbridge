import AirBridgeCore
import SwiftUI

@main
struct AirBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AirBridge", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                .onOpenURL { model.openLink($0) }
        }
        .handlesExternalEvents(matching: ["airbridge"])
        .commands {
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
}
