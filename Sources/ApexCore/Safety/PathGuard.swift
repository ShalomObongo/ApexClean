import Foundation

/// The single choke point every destructive operation must pass through.
///
/// The model is deliberately *fail-closed*: `PathGuard` answers "is this
/// provably safe to remove?", not "is this obviously dangerous?". Anything it
/// cannot positively vouch for is refused. Adapted from the safety boundaries in
/// the Mole CLI (GPL-3.0) — see NOTICE.
public enum PathGuard {
    public enum Verdict: Equatable {
        case allowed
        case refused(reason: String)

        public var isAllowed: Bool { self == .allowed }
        public var reason: String? {
            if case let .refused(reason) = self { return reason }
            return nil
        }
    }

    public static let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL

    // MARK: - Roots

    /// A removal target must live under exactly one of these. Anything else is
    /// outside the blast radius ApexClean is willing to operate in.
    private static let permittedRoots: [String] = [
        home.path,
        "/Library/Caches",
        "/Library/Logs",
        "/private/var/folders",
        "/var/folders",
        "/private/tmp",
        "/tmp",
        "/Users/Shared",
        "/Applications",
        "/Volumes",
    ]

    /// Paths that must never be removed, matched exactly (after standardizing).
    private static let immovable: Set<String> = {
        var paths: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/Volumes",
            "/private", "/private/var", "/private/tmp", "/tmp", "/bin", "/sbin",
            "/usr", "/usr/local", "/opt", "/etc", "/dev", "/cores", "/Network",
            "/Library/Caches", "/Library/Logs", "/Library/Application Support",
            "/Library/Preferences", "/Library/LaunchAgents", "/Library/LaunchDaemons",
            "/Users/Shared",
        ]
        let h = home.path
        for leaf in [
            "", "/Library", "/Library/Caches", "/Library/Logs", "/Library/Preferences",
            "/Library/Application Support", "/Library/Containers", "/Library/Group Containers",
            "/Library/LaunchAgents", "/Library/Developer", "/Library/Mobile Documents",
            "/Library/Keychains", "/Library/Safari", "/Library/Messages", "/Library/Mail",
            "/Library/Photos", "/Library/Application Scripts", "/Library/WebKit",
            "/Library/HTTPStorages", "/Library/Autosave Information", "/Library/Saved Application State",
            "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Movies", "/Music",
            "/Public", "/Applications", "/.Trash", "/.ssh", "/.gnupg", "/.config",
            "/.cache", "/.local", "/.local/share",
        ] {
            paths.insert(h + leaf)
        }
        return paths
    }()

    /// Directories whose *contents* are irreplaceable user data. Even a nested
    /// path underneath these is refused unless a narrower rule vouches for it.
    private static let sacredSubtrees: [String] = {
        let h = home.path
        return [
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Pictures", "\(h)/Movies",
            "\(h)/Music", "\(h)/Public", "\(h)/.ssh", "\(h)/.gnupg",
            "\(h)/Library/Keychains", "\(h)/Library/Mobile Documents",
            "\(h)/Library/Photos", "\(h)/Library/Mail/V10",
            "\(h)/Library/Application Support/AddressBook/AddressBook-v22.abcddb",
            "\(h)/Library/Messages/chat.db",
            "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/etc", "/dev",
            "/Library/Keychains", "/private/var/db",
        ]
    }()

    // MARK: - Case folding

    /// macOS volumes are case-insensitive by default, so `~/documents/thesis`
    /// and `~/Documents/thesis` are the *same file*. Every comparison below was
    /// case-sensitive, which meant a differently-cased path walked straight past
    /// the protection for irreplaceable personal data: `~/Documents/thesis.txt`
    /// was refused, and `~/documents/thesis.txt` was allowed.
    ///
    /// Folding case for every comparison is deliberately the over-protective
    /// choice. On a case-sensitive volume it may refuse a genuinely distinct
    /// directory that merely looks like a protected one — which is the correct
    /// direction to be wrong in for a guard that exists to fail closed.
    private static let loweredImmovable: Set<String> = Set(immovable.map { $0.lowercased() })
    private static let loweredSacredSubtrees: [String] = sacredSubtrees.map { $0.lowercased() }
    private static let loweredPermittedRoots: [String] = permittedRoots.map { $0.lowercased() }
    private static let loweredProtectedFragments: [String] = protectedFragments.map {
        $0.lowercased()
    }

    private static func isWithin(_ path: String, anyOf roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Substring rules that protect system UI surfaces which visibly break when
    /// their supposedly "regenerable" state is removed.
    private static let protectedFragments: [String] = [
        "SystemSettings", "systempreferences", "ControlCenter", "controlcenter",
        "com.apple.Settings", "com.apple.SystemSettings", "com.apple.controlcenter",
        "com.apple.finder", "com.apple.dock", "com.apple.notes",
        "com.apple.e5rt.e5bundlecache",
        "/Library/Group Containers/dev.orbstack", "/.orbstack",
    ]

    /// Endpoint-detection agents tamper-protect their scratch state. Removing a
    /// few MB of their cache is reported to IT as a tamper event, so the whole
    /// vendor namespace under the per-user Darwin folder is off limits.
    private static let endpointSecurityVendors: [String] = [
        "crowdstrike", "falcon", "sentinelone", "sentinel-one", "carbonblack",
        "cylance", "cortex", "paloaltonetworks", "globalprotect", "jamf",
        "microsoft.wdav", "defender", "trendmicro", "sophos", "eset",
        "mcafee", "symantec", "netskope", "zscaler", "cisco.secureclient",
        "tanium", "rapid7", "qualys", "nessus", "elastic.endpoint",
    ]

    // MARK: - Evaluation

    /// Evaluates a removal target. Callers must re-run this immediately before
    /// the deletion syscall, never only at scan time — the filesystem can change
    /// underneath a queued operation.
    public static func evaluate(_ url: URL, allowUserRoots: Bool = false) -> Verdict {
        let target = url.standardizedFileURL
        let path = normalize(target.path)

        if path.isEmpty || path == "/" {
            return .refused(reason: "Refuses to operate on the volume root")
        }
        if path.contains("\0") {
            return .refused(reason: "Path contains an invalid character")
        }
        if !path.hasPrefix("/") {
            return .refused(reason: "Only absolute paths can be removed")
        }
        if path.contains("/../") || path.hasSuffix("/..") {
            return .refused(reason: "Path traversal is not permitted")
        }

        let lowered = path.lowercased()
        if loweredImmovable.contains(lowered) {
            return .refused(reason: "This is a system or top-level directory")
        }

        // Depth floor: /a and /a/b are always too coarse to be a cleanup target.
        //
        // Application bundles are the one honest exception. `/Applications` is
        // a permitted root, so `/Applications/Thing.app` — the standard install
        // location for essentially every Mac app — is only two components deep.
        // Refusing it meant uninstall removed an app's caches, containers and
        // preferences and then left the app itself sitting there, reporting
        // only "refused by safety checks".
        let components = path.split(separator: "/").map(String.init)
        if components.count < 3, !isTopLevelApplicationBundle(components) {
            return .refused(reason: "Path is too close to the volume root")
        }

        if isMountPoint(target) {
            return .refused(reason: "This is a mounted volume root")
        }

        // Folded with the same locale-independent mapping as every other
        // comparison here. `localizedCaseInsensitiveContains` follows the
        // current locale, and under a Turkish locale dotted and dotless I are
        // distinct — so `COM.APPLE.FINDER` would not have matched
        // `com.apple.finder` and the path would not have been protected.
        for fragment in loweredProtectedFragments where lowered.contains(fragment) {
            return .refused(reason: "Protected system component")
        }

        if isEndpointSecurityPath(path) {
            return .refused(reason: "Belongs to an endpoint-security agent")
        }

        if !allowUserRoots, isWithin(lowered, anyOf: loweredSacredSubtrees) {
            return .refused(reason: "Contains irreplaceable personal data")
        }

        guard isWithin(lowered, anyOf: loweredPermittedRoots) else {
            return .refused(reason: "Outside the directories ApexClean may modify")
        }

        // A symlink is removed as a link; we never chase it into foreign storage.
        if let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey]),
            values.isSymbolicLink == true
        {
            return .allowed
        }

        // Re-validate the fully resolved path so a symlinked *parent* cannot be
        // used to smuggle a target out of the permitted roots.
        let resolved = normalize(target.resolvingSymlinksInPath().path)
        if resolved != path {
            let loweredResolved = resolved.lowercased()
            if loweredImmovable.contains(loweredResolved) {
                return .refused(reason: "Resolves to a system directory")
            }
            if !allowUserRoots, isWithin(loweredResolved, anyOf: loweredSacredSubtrees) {
                return .refused(reason: "Resolves into irreplaceable personal data")
            }
            let resolvedRoots =
                loweredPermittedRoots
                + ["/private\(home.path)".lowercased(), "/system/volumes/data"]
            guard isWithin(loweredResolved, anyOf: resolvedRoots) else {
                return .refused(reason: "Resolves outside the permitted directories")
            }
        }

        return .allowed
    }

    /// True when the *bundle* may be uninstalled. Stricter than path evaluation:
    /// system-critical bundle identifiers are refused outright.
    public static func canUninstall(bundleID: String, path: URL) -> Verdict {
        let identifier = bundleID.lowercased()
        for critical in SystemCriticalBundles.identifiers where matches(identifier, pattern: critical) {
            return .refused(reason: "Required by macOS")
        }
        let location = path.standardizedFileURL.path
        // Case-folded for the same reason `evaluate` is: on a case-insensitive
        // volume `/system/Applications/Mail.app` is the same file as
        // `/System/...`, and a byte-exact prefix test would wave it through.
        let lowered = location.lowercased()
        if lowered.hasPrefix("/system/") {
            return .refused(reason: "Part of the sealed system volume")
        }
        if lowered == "/applications" || lowered == "/applications/utilities" {
            return .refused(reason: "Not an application bundle")
        }
        guard lowered.hasSuffix(".app") else {
            return .refused(reason: "Not an application bundle")
        }
        return .allowed
    }

    // MARK: - Helpers

    private static func normalize(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// `/Applications/Thing.app`, and nothing else.
    ///
    /// Deliberately narrow: it requires the exact two-component shape, the
    /// literal `Applications` root and the `.app` suffix, so it cannot be used
    /// to reach `/Applications` itself or any other shallow path.
    private static func isTopLevelApplicationBundle(_ components: [String]) -> Bool {
        guard components.count == 2 else { return false }
        let root = components[0].lowercased()
        let leaf = components[1].lowercased()
        // Case-folded, because everything else here is: a case-exact test would
        // refuse `/applications/Thing.app` — the same file — and so quietly
        // reinstate the bug this exception was added to fix.
        return root == "applications" && leaf.hasSuffix(".app") && leaf.count > 4
    }

    private static func isEndpointSecurityPath(_ path: String) -> Bool {
        guard path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") else { return false }
        let lower = path.lowercased()
        return endpointSecurityVendors.contains { lower.contains($0) }
    }

    private static func isMountPoint(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isVolumeKey]) else { return false }
        return values.isVolume == true
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        let lowered = pattern.lowercased()
        if lowered.hasSuffix("*") {
            return value.hasPrefix(String(lowered.dropLast()))
        }
        return value == lowered
    }
}

/// Bundle identifiers that must survive any uninstall. Apple apps are listed
/// explicitly rather than wildcarded on `com.apple.*` so that user-installed
/// Apple software (Xcode, Final Cut Pro, Logic) remains removable.
public enum SystemCriticalBundles {
    public static let identifiers: [String] = [
        "com.apple.finder", "com.apple.dock", "com.apple.safari", "com.apple.mail",
        "com.apple.systempreferences*", "com.apple.settings*", "com.apple.controlcenter*",
        "com.apple.spotlight", "com.apple.notificationcenterui", "com.apple.loginwindow",
        "com.apple.preview", "com.apple.textedit", "com.apple.notes", "com.apple.reminders",
        "com.apple.ical", "com.apple.addressbook", "com.apple.photos", "com.apple.appstore",
        "com.apple.calculator", "com.apple.dictionary", "com.apple.screensharing",
        "com.apple.activitymonitor", "com.apple.console", "com.apple.diskutility",
        "com.apple.keychainaccess", "com.apple.digitalcolormeter", "com.apple.grapher",
        "com.apple.terminal", "com.apple.scripteditor2", "com.apple.voiceoverutility",
        "com.apple.bluetoothfileexchange", "com.apple.systemprofiler", "com.apple.fontbook",
        "com.apple.colorsyncutility", "com.apple.audio.audiomidisetup", "com.apple.directoryutility",
        "com.apple.migrateassistant", "com.apple.bootcampassistant", "com.apple.securityagent",
        "com.apple.coreservices*", "com.apple.systemuiserver", "com.apple.security*",
        "com.apple.keychain*", "com.apple.trustd*", "com.apple.securityd*", "com.apple.cloudd*",
        "com.apple.icloud*", "com.apple.wifi*", "com.apple.airport*", "com.apple.bluetooth*",
        "com.apple.inputmethod.*", "com.apple.textinput*", "com.apple.installer*",
        "com.apple.softwareupdate*", "com.apple.mobilesoftwareupdate*", "com.apple.metadata*",
        "com.apple.sharedfilelist*", "com.apple.backgroundtaskmanagement*",
        "fit.apexclean.app",
    ]
}
