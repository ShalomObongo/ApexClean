import AppKit
import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
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

    public enum Source: String, Sendable {
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
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            PathGuard.home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications/Setapp"),
            PathGuard.home.appendingPathComponent("Applications/Setapp"),
        ]
        return Array(
            Dictionary(
                grouping: roots.map(\.standardizedFileURL),
                by: \.path
            ).compactMap { $0.value.first }
        )
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
        // Resolved from the Caskroom's own symlinks rather than guessed from
        // the app's name. The guess was wrong in both directions: it missed
        // casks whose token differs from the bundle name (`ollama-app` for
        // Ollama, `opencode-desktop` for OpenCode, `prismlauncher` for "Prism
        // Launcher"), and would claim a hand-installed app that merely shared a
        // name with some cask in the index.
        let caskByPath = HomebrewBridge.caskTokensByAppPath()
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for root in searchRoots {
            let contents = Guarded.run(budget: 4) {
                try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .addedToDirectoryDateKey],
                    options: [.skipsHiddenFiles]
                )
            }
            guard let contents = (contents ?? nil) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                if let app = describe(url, running: running, caskByPath: caskByPath) {
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

        let sizes = SizeBuffer(count: apps.count)
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            sizes.set(FileSize.measure(apps[index].url).bytes, at: index)
        }

        return zip(apps, sizes.values()).map { app, bytes in
            var copy = app
            copy.bundleBytes = bytes
            return copy
        }
    }

    static func describe(
        _ url: URL,
        running: RunningAppsSnapshot,
        caskByPath: [String: String]
    ) -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        let bundleID = bundle.bundleIdentifier ?? ""
        let name =
            (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version =
            (info["CFBundleShortVersionString"] as? String)
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
        let isSystem = url.resolvingSymlinksInPath().path.hasPrefix("/System/")

        let source: InstalledApp.Source
        if isSystem {
            source = .system
        } else if hasReceipt {
            source = .appStore
        } else if caskByPath[url.standardizedFileURL.path] != nil {
            source = .homebrew
        } else {
            source = .direct
        }

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

    private final class SizeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int64]

        init(count: Int) {
            storage = [Int64](repeating: 0, count: count)
        }

        func set(_ value: Int64, at index: Int) {
            lock.lock()
            storage[index] = value
            lock.unlock()
        }

        func values() -> [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}

/// Thin, entirely optional Homebrew integration. Everything degrades to "no
/// data" when brew is absent rather than becoming an error the user must resolve.
public enum HomebrewBridge {
    public static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { Shell.exists($0) }
    }

    public static var isAvailable: Bool { brewPath != nil }

    /// Maps an installed application path to the cask that owns it.
    ///
    /// Resolved from the Caskroom itself rather than guessed from the app's
    /// name. Every app cask stages `Caskroom/<token>/<version>/Thing.app` as a
    /// symlink to the real bundle, so following that link answers the question
    /// exactly — including for casks whose token bears no resemblance to the
    /// app name, and without falsely claiming a hand-installed app that merely
    /// shares a name with some cask.
    public static func caskTokensByAppPath() -> [String: String] {
        guard let brew = brewPath else { return [:] }
        let prefix = URL(fileURLWithPath: brew)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let caskroom = prefix.appendingPathComponent("Caskroom")
        let fm = FileManager.default
        guard let tokens = try? fm.contentsOfDirectory(at: caskroom, includingPropertiesForKeys: nil)
        else { return [:] }

        var map: [String: String] = [:]
        for token in tokens {
            guard let versions = try? fm.contentsOfDirectory(at: token, includingPropertiesForKeys: nil)
            else { continue }
            for version in versions {
                guard
                    let staged = try? fm.contentsOfDirectory(
                        at: version, includingPropertiesForKeys: nil)
                else { continue }
                for item in staged where item.pathExtension == "app" {
                    let target = item.resolvingSymlinksInPath().standardizedFileURL.path
                    map[target] = token.lastPathComponent
                }
            }
        }
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]) { _, new in new }
        let metadata = Shell.runDetailed(
            brew,
            ["info", "--cask", "--json=v2", "--installed"],
            timeout: 30,
            environment: environment
        )
        if metadata.succeeded {
            map.merge(parseCaskAppOwners(metadata.output.data(using: .utf8) ?? Data())) {
                current, _ in current
            }
        }
        return map
    }

    static func parseCaskAppOwners(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let casks = root["casks"] as? [[String: Any]]
        else { return [:] }

        var result: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String,
                let artifacts = cask["artifacts"]
            else { continue }
            for raw in strings(in: artifacts) where raw.lowercased().hasSuffix(".app") {
                let expanded = raw.expandingTilde
                let candidates =
                    expanded.hasPrefix("/")
                    ? [expanded]
                    : [
                        "/Applications/\(expanded)",
                        PathGuard.home.appendingPathComponent("Applications/\(expanded)").path,
                    ]
                for path in candidates {
                    result[URL(fileURLWithPath: path).standardizedFileURL.path] = token
                }
            }
        }
        return result
    }

    private static func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(strings) }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(strings)
        }
        return []
    }

    public static func installedCaskTokens() -> Set<String> {
        guard let brew = brewPath,
            let output = Shell.run(brew, ["list", "--cask", "-1"], timeout: 12)
        else { return [] }
        return Set(output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    public struct OutdatedCask: Identifiable, Hashable, Sendable {
        public var id: String { token }
        public let token: String
        public let currentVersion: String
        public let latestVersion: String
    }

    /// Whether the update check produced a trustworthy answer.
    ///
    /// An empty list is ambiguous — it means "nothing is outdated" *or* "the
    /// command never finished" — and the two must not look the same to the
    /// user.
    public struct OutdatedResult: Sendable {
        public let casks: [OutdatedCask]
        public let didComplete: Bool
        public var isReliable: Bool { didComplete }
    }

    public static func outdatedCasks() -> [OutdatedCask] {
        outdatedCaskResult().casks
    }

    public static func outdatedCaskResult() -> OutdatedResult {
        guard let brew = brewPath else { return OutdatedResult(casks: [], didComplete: false) }

        // `HOMEBREW_NO_AUTO_UPDATE` is the difference between a check and a
        // gamble. Without it, `brew outdated` first runs a full `brew update`,
        // which fetches every tap over the network. On a slow connection that
        // alone can exceed the timeout — and a timed-out check returned an
        // empty list, which the UI rendered as "everything is up to date".
        // Reporting "no updates" because the check never ran is the one answer
        // an update feature must never give.
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]) { _, new in new }

        let result = Shell.runDetailed(
            brew,
            ["outdated", "--cask", "--greedy", "--verbose"],
            timeout: 90,
            environment: environment
        )
        guard !result.timedOut, result.status == 0 else {
            return OutdatedResult(casks: [], didComplete: false)
        }
        return OutdatedResult(casks: parseOutdatedCasks(result.output), didComplete: true)
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
            let token = String(text[text.startIndex..<openParen]).trimmingCharacters(in: .whitespaces)
            let current = String(text[text.index(after: openParen)..<closeParen])
                .trimmingCharacters(in: .whitespaces)
            let latest = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, !current.isEmpty, !latest.isEmpty, current != latest else { return nil }
            return OutdatedCask(token: token, currentVersion: current, latestVersion: latest)
        }
    }

    @discardableResult
    public static func upgradeCask(_ token: String) -> Bool {
        upgrade(token).succeeded
    }

    public struct UpgradeOutcome: Sendable {
        public let succeeded: Bool
        /// Short, human-readable reason. Empty when the upgrade worked.
        public let message: String
    }

    /// Upgrades one cask and reports what actually happened.
    ///
    /// Success is the process exit status, never "we got some output" — brew
    /// prints plenty while failing. `--greedy` matches how the outdated list is
    /// built, so casks that auto-update are actually upgradeable rather than
    /// listed and then refused.
    public static func upgrade(_ token: String) -> UpgradeOutcome {
        guard let brew = brewPath else {
            return UpgradeOutcome(succeeded: false, message: "Homebrew is not installed")
        }

        var environment = ProcessInfo.processInfo.environment
        // Non-interactive: a sudo or confirmation prompt here would block on a
        // question the user can never be asked, so brew must fail fast instead.
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["SUDO_ASKPASS"] = "/nonexistent"

        let result = Shell.runDetailed(
            brew,
            ["upgrade", "--cask", "--greedy", token],
            timeout: 900,
            environment: environment
        )

        if result.succeeded { return UpgradeOutcome(succeeded: true, message: "") }
        if result.timedOut {
            return UpgradeOutcome(succeeded: false, message: "Timed out after 15 minutes")
        }
        return UpgradeOutcome(succeeded: false, message: describe(failure: result))
    }

    /// Turns brew's output into one sentence worth showing.
    ///
    /// Deliberately not clever. An earlier version pattern-matched loosely for
    /// "quit" and "sudo", and cheerfully reported "Quit the app first" for an
    /// error that read `invalid option: --no-quarantine` — a confident, wrong
    /// diagnosis, which is worse than no diagnosis. Only two conditions are
    /// recognised, both by unambiguous markers; everything else is quoted.
    static func describe(failure result: Shell.Result) -> String {
        let lines = result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let errorLine = lines.last { $0.hasPrefix("Error:") }
        let text = errorLine.map {
            String($0.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
        }

        let haystack = (text ?? result.output).lowercased()
        if haystack.contains("password is required") || haystack.contains("sudo: a terminal") {
            return "Needs an administrator password. Run `brew upgrade --cask <name>` in Terminal."
        }
        if haystack.contains("is currently running") || haystack.contains("application is open") {
            return "Quit the app first, then try again."
        }
        // macOS 13+ stops one app from modifying another unless App Management
        // is granted. brew reports it as a bare permissions error, which tells
        // nobody where to go.
        if haystack.contains("operation not permitted") || haystack.contains("permission denied") {
            return
                "macOS blocked this. Allow ApexClean under Privacy & Security → App Management, then try again."
        }
        return text ?? result.lastMeaningfulLine ?? "Homebrew reported an error"
    }
}
