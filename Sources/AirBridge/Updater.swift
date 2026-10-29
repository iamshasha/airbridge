import AirBridgeCore
import AppKit
import Observation

/// Checks GitHub Releases for a newer AirBridge and installs it: download, unzip, swap the app bundle
/// once this copy has quit, relaunch.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdate)
        case downloading(Double)
        case installing
        case failed(String)
    }

    var state: State = .idle
    /// The update sheet is up (after "Check for Updates…", or when an automatic check finds something).
    var showing = false
    var lastChecked: Date? { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdates") }
    }

    static let asset = "AirBridge-macOS.zip"

    var currentVersion: String { UpdateChecker.currentVersion }

    /// Called at launch: quietly checks once a day.
    func checkInBackground() {
        // Test hook: AIRBRIDGE_UPDATE_TEST=1 checks now and installs whatever it finds, without any clicks.
        if ProcessInfo.processInfo.environment["AIRBRIDGE_UPDATE_TEST"] == "1" {
            Task {
                if let update = try? await UpdateChecker.check(asset: Self.asset) { install(update) } else { state = .upToDate }
            }
            return
        }
        guard checksAutomatically, UpdateChecker.isDue(lastCheck: lastChecked) else { return }
        Task {
            if let update = try? await UpdateChecker.check(asset: Self.asset) {
                state = .available(update)
                showing = true
            }
            UserDefaults.standard.set(Date.now, forKey: "lastUpdateCheck")
        }
    }

    func check() {
        state = .checking
        Task {
            do {
                let update = try await UpdateChecker.check(asset: Self.asset)
                UserDefaults.standard.set(Date.now, forKey: "lastUpdateCheck")
                state = update.map(State.available) ?? .upToDate
            } catch {
                state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            }
        }
    }

    func install(_ update: AppUpdate) {
        let bundle = Bundle.main.bundleURL
        // Run from `swift run`, or from a folder this user can't write to: the release page does the job.
        guard bundle.pathExtension == "app", let download = update.downloadURL,
              FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        state = .downloading(0)
        Task {
            do {
                let zip = try await Downloader.download(download) { fraction in
                    Task { @MainActor in self.state = .downloading(fraction) }
                }
                state = .installing
                let newApp = try await Task.detached { try Self.unpack(zip) }.value
                try relaunch(replacing: bundle, with: newApp)
            } catch {
                state = .failed("Couldn't install the update: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func unpack(_ zip: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AirBridge-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        let app = folder.appendingPathComponent("AirBridge.app")
        guard FileManager.default.fileExists(atPath: app.path),
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw AirBridgeError.protocolViolation("the download isn't an AirBridge app")
        }
        // Refuse a damaged or tampered bundle.
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        return app
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AirBridgeError.protocolViolation("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))")
        }
    }

    /// A tiny script waits for this process to exit, swaps the bundles and opens the new one.
    private func relaunch(replacing current: URL, with new: URL) throws {
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$OLD"
        mv "$TARGET" "$OLD" && mv "$NEW" "$TARGET" && rm -rf "$OLD"
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        open "$TARGET"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["TARGET": current.path, "NEW": new.path, "OLD": current.path + ".old"]
        try process.run()
        NSApp.terminate(nil)
    }
}

/// URLSession download with progress callbacks.
enum Downloader {
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress)
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AirBridgeError.protocolViolation("download failed") }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: temp, to: kept)
        return kept
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
