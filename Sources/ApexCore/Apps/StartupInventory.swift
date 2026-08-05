import AppKit
import Foundation

/// Something macOS starts on your behalf.
public struct StartupItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let label: String
    public let displayName: String
    public let programPath: String?
    public let scope: Scope
    public let runsAtLoad: Bool
    /// True when the referenced binary no longer exists — a leftover that costs
    /// launchd a failed spawn on every login.
    public let isOrphaned: Bool
    public let isApple: Bool

    public enum Scope: String, CaseIterable, Sendable {
        case userAgent = "Login item"
        case globalAgent = "System agent"
        case daemon = "System daemon"

        public var detail: String {
            switch self {
            case .userAgent: "Starts when you log in"
            case .globalAgent: "Starts for every user"
            case .daemon: "Starts before login, runs as root"
            }
        }

        public var requiresAdmin: Bool { self != .userAgent }
    }

    public var displayPath: String { Glob.display(url.path) }
}

public enum StartupInventory {
    public static func scan() -> [StartupItem] {
        var items: [StartupItem] = []
        let roots: [(URL, StartupItem.Scope)] = [
            (PathGuard.home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]

        for (root, scope) in roots {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for url in contents where url.pathExtension == "plist" {
                if let item = describe(url, scope: scope) { items.append(item) }
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.isOrphaned != rhs.isOrphaned { return lhs.isOrphaned }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func describe(_ url: URL, scope: StartupItem.Scope) -> StartupItem? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent

        // `Program` and `ProgramArguments` are alternatives; the first argument
        // of the latter is the executable.
        var program = plist["Program"] as? String
        if program == nil, let arguments = plist["ProgramArguments"] as? [String] {
            program = arguments.first
        }

        let runsAtLoad = (plist["RunAtLoad"] as? Bool ?? false) || (plist["KeepAlive"] as? Bool ?? false)
        let isApple = label.hasPrefix("com.apple.")

        var orphaned = false
        if let program, !isApple {
            // A relative path means launchd resolves it against PATH; we cannot
            // prove absence, so we do not claim it.
            if program.hasPrefix("/") {
                if let volumeRoot = mountedVolumeRoot(for: program),
                    !FileManager.default.fileExists(atPath: volumeRoot)
                {
                    orphaned = false
                } else {
                    orphaned = !FileManager.default.fileExists(atPath: program)
                }
            }
        }

        return StartupItem(
            url: url,
            label: label,
            displayName: friendlyName(label: label, program: program),
            programPath: program,
            scope: scope,
            runsAtLoad: runsAtLoad,
            isOrphaned: orphaned,
            isApple: isApple
        )
    }

    /// Turns "com.vendor.product.helper" into something a person can recognise.
    static func friendlyName(label: String, program: String?) -> String {
        if let program, program.contains(".app/") {
            let components = program.components(separatedBy: ".app/")
            if let bundlePath = components.first,
                let name = bundlePath.components(separatedBy: "/").last, !name.isEmpty
            {
                return name
            }
        }

        let parts = label.split(separator: ".")
        guard parts.count >= 2 else { return label }

        // Reverse-DNS: the vendor is usually the second component, the product
        // the third. Prefer the product, fall back to the vendor.
        let candidate = parts.count >= 3 ? String(parts[2]) : String(parts[1])
        let cleaned =
            candidate
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        guard !cleaned.isEmpty else { return label }
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }

    /// Unloads a launchd job before its plist is removed, so the running process
    /// does not linger until reboot.
    @discardableResult
    public static func unload(_ item: StartupItem) -> Bool {
        guard item.scope == .userAgent else { return false }
        let launchctl = "/bin/launchctl"
        guard Shell.exists(launchctl) else { return false }
        let uid = getuid()
        return Shell.runDetailed(
            launchctl,
            ["bootout", "gui/\(uid)/\(item.label)"],
            timeout: 8
        ).succeeded
    }

    public static func unload(plist url: URL) -> Bool {
        let userRoot = PathGuard.home.appendingPathComponent("Library/LaunchAgents").path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(userRoot + "/"),
            let item = describe(url, scope: .userAgent),
            !item.isApple
        else { return false }
        return unload(item)
    }

    private static func mountedVolumeRoot(for path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        return "/Volumes/\(components[1])"
    }
}
