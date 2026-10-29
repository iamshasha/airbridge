import Foundation

/// A newer AirBridge published on GitHub Releases.
public struct AppUpdate: Sendable, Equatable {
    public var version: String
    public var notes: String
    /// The release page, for platforms that can't install by themselves (iOS).
    public var pageURL: URL
    /// This platform's download, if the release has one.
    public var downloadURL: URL?
    public var downloadSize: Int64
}

/// Checks github.com/iamshasha/airbridge for a newer release. Public repo, so no sign-in is needed.
public enum UpdateChecker {
    public static let latestURL = URL(string: "https://api.github.com/repos/iamshasha/airbridge/releases/latest")!

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// The running app's version (CFBundleShortVersionString).
    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Returns the latest release when it is newer than `current`, or nil when this is up to date.
    /// `asset` is the file name this platform installs from (e.g. "AirBridge-macOS.zip").
    public static func check(current: String = currentVersion, asset: String?) async throws -> AppUpdate? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AirBridge/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil } // no releases yet
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AirBridgeError.protocolViolation("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try parse(data, current: current, asset: asset)
    }

    static func parse(_ data: Data, current: String, asset: String?) throws -> AppUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true, isNewer(release.tag_name, than: current) else { return nil }
        let file = release.assets.first { $0.name == asset }
        return AppUpdate(version: normalized(release.tag_name), notes: release.body ?? "", pageURL: release.html_url,
                         downloadURL: file?.browser_download_url, downloadSize: file?.size ?? 0)
    }

    static func normalized(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }

    /// Numeric comparison, part by part: 0.10.0 is newer than 0.9.2.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            normalized(v).split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Automatic checks happen at most once a day.
    public static func isDue(lastCheck: Date?, now: Date = .now) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > 24 * 3600
    }
}
