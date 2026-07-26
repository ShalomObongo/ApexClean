import Foundation
import AppKit

public struct InstalledApp: Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public var bundleBytes: Int64
    public let lastUsed: Date?
    public let installed: Date?
    public let isRunning: Bool
    public let isSystem: Bool
    /// True when the bundle came from the App Store or a Homebrew cask, which
    /// changes the honest advice about how to update it.
    public let source: Source

    public enum Source: String {
        case appStore = "App Store"
        case homebrew = "Homebrew"
        case direct = "Downloaded"
        case system = "macOS"
    }

    public var idleDays: Int? {
        guard let lastUsed else { return nil }
        return Int(Date().timeIntervalSince(lastUsed) / 86_400)
    }

    public var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Enumerates installed applications and the facts needed to reason about them.
public enum AppInventory {
    private static var searchRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            PathGuard.home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications/Setapp"),
        ]
    }

    /// Enumerates installed apps *without* measuring them.
    ///
    /// Measuring a bundle means walking its entire contents, which for a few
    /// dozen apps is several seconds of solid I/O. Discovery is separated from
    /// measurement so the UI can show a complete, correct list immediately and
    /// fill sizes in afterwards.
    /// - Parameter running: Captured on the main actor by the caller, because
    ///   `NSWorkspace` must not be queried from a background thread.
    public static func scan(
        running: RunningAppsSnapshot = RunningAppsSnapshot(),
        includeSystem: Bool = false
    ) -> [InstalledApp] {
        let caskNames = HomebrewBridge.installedCaskTokens()
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in searchRoots {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .addedToDirectoryDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                if let app = describe(url, running: running, caskTokens: caskNames) {
                    if app.isSystem, !includeSystem { continue }
                    apps.append(app)
                }
            }
        }

        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Measures bundle sizes across all cores.
    ///
    /// Bundle measurement is I/O bound and embarrassingly parallel, so this is
    /// roughly an order of magnitude faster than the serial walk on any modern
    /// Mac while keeping each result attributable to its app.
    public static func measured(_ apps: [InstalledApp]) -> [InstalledApp] {
        guard !apps.isEmpty else { return [] }

        var sizes = [Int64](repeating: 0, count: apps.count)
        sizes.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: apps.count) { index in
                buffer[index] = FileSize.measure(apps[index].url).bytes
            }
        }

        return zip(apps, sizes).map { app, bytes in
            var copy = app
            copy.bundleBytes = bytes
            return copy
        }
    }

    static func describe(
        _ url: URL,
        running: RunningAppsSnapshot,
        caskTokens: Set<String>
    ) -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        let bundleID = bundle.bundleIdentifier ?? ""
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "—"

        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .addedToDirectoryDateKey,
            .contentAccessDateKey,
        ]
        let values = try? url.resourceValues(forKeys: resourceKeys)

        // The App Store receipt is the only reliable marker of a Mac App Store install.
        let hasReceipt = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )
        let token = url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        let isSystem = url.path.hasPrefix("/System/") || bundleID.hasPrefix("com.apple.")

        let source: InstalledApp.Source
        if isSystem { source = .system }
        else if hasReceipt { source = .appStore }
        else if caskTokens.contains(token) { source = .homebrew }
        else { source = .direct }

        return InstalledApp(
            url: url,
            name: name,
            bundleID: bundleID,
            version: version,
            bundleBytes: 0,
            lastUsed: values?.contentAccessDate,
            installed: values?.addedToDirectoryDate ?? values?.contentModificationDate,
            isRunning: running.contains(bundleID),
            isSystem: isSystem,
            source: source
        )
    }
}

/// Thin, entirely optional Homebrew integration. Everything degrades to "no
/// data" when brew is absent rather than becoming an error the user must resolve.
public enum HomebrewBridge {
    public static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { Shell.exists($0) }
    }

    public static var isAvailable: Bool { brewPath != nil }

    public static func installedCaskTokens() -> Set<String> {
        guard let brew = brewPath,
              let output = Shell.run(brew, ["list", "--cask", "-1"], timeout: 12)
        else { return [] }
        return Set(output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    public struct OutdatedCask: Identifiable, Hashable {
        public var id: String { token }
        public let token: String
        public let currentVersion: String
        public let latestVersion: String
    }

    public static func outdatedCasks() -> [OutdatedCask] {
        guard let brew = brewPath,
              let output = Shell.run(brew, ["outdated", "--cask", "--greedy", "--verbose"], timeout: 90)
        else { return [] }
        return parseOutdatedCasks(output)
    }

    /// Parses `brew outdated --cask --greedy --verbose`, whose lines read
    /// `token (1.2.3) != 1.3.0`.
    ///
    /// `--greedy` also returns casks declared `version :latest`, which report
    /// as `latest != latest`. Homebrew is saying it cannot compare them, not
    /// that a newer build exists — so they are dropped. Presenting an update
    /// that may be a no-op would inflate the count and teach people to
    /// distrust the number, which is worse than missing an unversioned app.
    static func parseOutdatedCasks(_ output: String) -> [OutdatedCask] {
        output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard let openParen = text.firstIndex(of: "("),
                  let closeParen = text.range(of: ")", options: .backwards)?.lowerBound,
                  openParen < closeParen,
                  let separator = text.range(of: "!="),
                  closeParen < separator.lowerBound
            else { return nil }
            let token = String(text[text.startIndex ..< openParen]).trimmingCharacters(in: .whitespaces)
            let current = String(text[text.index(after: openParen) ..< closeParen])
                .trimmingCharacters(in: .whitespaces)
            let latest = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, !current.isEmpty, !latest.isEmpty, current != latest else { return nil }
            return OutdatedCask(token: token, currentVersion: current, latestVersion: latest)
        }
    }

    @discardableResult
    public static func upgradeCask(_ token: String) -> Bool {
        guard let brew = brewPath else { return false }
        let output = Shell.run(brew, ["upgrade", "--cask", token], timeout: 600)
        return output != nil
    }
}
