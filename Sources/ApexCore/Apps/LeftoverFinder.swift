import Foundation

/// A file or directory believed to belong to a specific application.
public struct Leftover: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let kind: Kind
    /// Why this path is believed to belong to the app. Shown verbatim in review,
    /// because "trust me" is not an acceptable justification for deleting
    /// someone's data.
    public let evidence: String
    /// How strong that evidence actually is.
    ///
    /// This exists so the review can preselect on the *strength* of a match
    /// rather than by pattern-matching the evidence sentence, which silently
    /// preselected shared vendor directories.
    public var confidence: Confidence = .derivedName
    /// True when macOS would not let us read the path to size it. The item is
    /// still real and still belongs to the app — only the number is missing,
    /// and saying so is better than printing a confident zero.
    public var sizeIsUnknown: Bool = false

    public enum Confidence: String, Sendable {
        /// The path is named for the app's bundle identifier, which is unique
        /// to this vendor's app by construction.
        case bundleIdentifier
        /// The path carries the app's full name.
        case exactName
        /// The path matches a name derived from the app's — a base name, or a
        /// lowercase dotfile form. Plausible, but it can belong to a sibling
        /// product, so it is never preselected.
        case derivedName

        /// Whether a match this strong may be ticked before the user has looked
        /// at it. Anything weaker is listed but left for them to decide.
        public var isSafeToPreselect: Bool {
            switch self {
            case .bundleIdentifier: true
            case .exactName, .derivedName: false
            }
        }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case support = "Application Support"
        case caches = "Caches"
        case preferences = "Preferences"
        case containers = "Containers"
        case logs = "Logs"
        case savedState = "Saved State"
        case launchAgents = "Launch Agents"
        case webData = "Web Data"
        case plugins = "Plug-ins"
        case other = "Other"

        public var symbol: String {
            switch self {
            case .support: "folder"
            case .caches: "shippingbox"
            case .preferences: "slider.horizontal.3"
            case .containers: "cube.box"
            case .logs: "doc.text"
            case .savedState: "arrow.uturn.backward"
            case .launchAgents: "bolt.badge.clock"
            case .webData: "globe"
            case .plugins: "puzzlepiece.extension"
            case .other: "doc"
            }
        }
    }

    public var displayPath: String { Glob.display(url.path) }
}

public struct UninstallPlan: Sendable {
    public let app: InstalledApp
    public var bundle: URL
    public var leftovers: [Leftover]
    public var uninstallVerdict: PathGuard.Verdict = .allowed
    /// Files that belong to this app but sit outside the blast radius
    /// ApexClean will operate in — almost always root-owned launch daemons and
    /// privileged helpers under `/Library`.
    ///
    /// These used to be discovered and then discarded before they reached the
    /// review, so an "uninstall" left a root daemon running and said nothing at
    /// all. They cannot be removed without administrator rights, but the user
    /// is entitled to know they are there.
    public var requiresAdmin: [Leftover] = []

    public var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: Int64 { app.bundleBytes + leftoverBytes }

    /// Items macOS would not let us measure. The uninstall total is therefore a
    /// floor, not an estimate, and the review says so.
    public var unmeasurable: [Leftover] { leftovers.filter(\.sizeIsUnknown) }

    public var grouped: [(kind: Leftover.Kind, items: [Leftover])] {
        Leftover.Kind.allCases.compactMap { kind in
            let items = leftovers.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items.sorted { $0.bytes > $1.bytes })
        }
    }
}

/// Finds the files an application leaves behind.
///
/// Matching is intentionally strict. A bundle identifier match is exact or
/// dot-boundary anchored; a display-name match must clear a length floor and
/// avoid generic words. Adapted from the Mole CLI's discovery rules (GPL-3.0).
public enum LeftoverFinder {
    /// Names too generic to match on. "Notes" or "Mail" would otherwise sweep up
    /// unrelated vendors' folders.
    private static let ambiguousNames: Set<String> = [
        "app", "mail", "notes", "music", "photos", "safari", "system", "helper",
        "update", "updater", "install", "installer", "service", "agent", "core",
        "data", "cache", "log", "logs", "temp", "tmp", "shared", "common",
        "desktop", "library", "user", "users", "main", "test", "demo", "preview",
    ]

    public static func plan(for app: InstalledApp) -> UninstallPlan {
        var app = app
        // The inventory defers bundle measurement for speed; the uninstall
        // review must show a real number, so measure it here if it is missing.
        if app.bundleBytes == 0 {
            let url = app.url
            app.bundleBytes = Guarded.run(budget: 20) { FileSize.measure(url).bytes } ?? 0
        }
        var found: [String: Leftover] = [:]
        var elevated: [String: Leftover] = [:]

        let bundleID = app.bundleID
        let bundleIDIsUsable = isReverseDNS(bundleID)
        let name = app.name
        let nameIsUsable =
            isSafePathComponent(name)
            && name.count >= 4
            && !ambiguousNames.contains(name.lowercased())

        func add(
            _ url: URL,
            _ kind: Leftover.Kind,
            _ evidence: String,
            _ confidence: Leftover.Confidence = .derivedName
        ) {
            let path = url.standardizedFileURL.path
            guard found[path] == nil else { return }
            let exists =
                Guarded.run(budget: 1) {
                    FileManager.default.fileExists(atPath: path)
                } ?? false
            guard exists else { return }

            guard PathGuard.evaluate(url).isAllowed else {
                // Only identifier-bound system artifacts are strong enough to
                // report outside ApexClean's writable roots. A display name is
                // app-controlled metadata and can never justify bypass advice.
                guard confidence == .bundleIdentifier else { return }
                elevated[path] = Leftover(
                    url: url,
                    bytes: Guarded.run(budget: 3) { FileSize.measure(url).bytes } ?? 0,
                    kind: kind,
                    evidence: evidence,
                    confidence: confidence
                )
                return
            }

            // Sandbox containers and the other consent-gated stores are the
            // reason this is not a straight `FileSize.measure`. Without Full
            // Disk Access, reading one does not fail — it blocks in the kernel,
            // forever, on a thread that can no longer be cancelled. Every app
            // with a container would otherwise wedge its own uninstall review.
            //
            // The path is still reported, because it is genuinely the app's
            // data and hiding it would make the uninstall incomplete. Only the
            // size is left unknown.
            if PrivacyAccess.requiresConsent(path) {
                found[path] = Leftover(
                    url: url,
                    bytes: 0,
                    kind: kind,
                    evidence: evidence,
                    confidence: confidence,
                    sizeIsUnknown: true
                )
                return
            }

            let measured = Guarded.run(budget: 6) { FileSize.measure(url).bytes }
            found[path] = Leftover(
                url: url,
                bytes: measured ?? 0,
                kind: kind,
                evidence: evidence,
                confidence: confidence,
                sizeIsUnknown: measured == nil
            )
        }

        let home = PathGuard.home

        // 1. Exact bundle-identifier paths. Highest confidence: the identifier is
        //    unique to this vendor's app by construction.
        if bundleIDIsUsable {
            let evidence = "Named for bundle identifier \(bundleID)"
            let byID: [(String, Leftover.Kind)] = [
                ("Library/Application Support/\(bundleID)", .support),
                ("Library/Caches/\(bundleID)", .caches),
                ("Library/Logs/\(bundleID)", .logs),
                ("Library/Preferences/\(bundleID).plist", .preferences),
                ("Library/Preferences/\(bundleID)", .preferences),
                ("Library/Containers/\(bundleID)", .containers),
                ("Library/Application Scripts/\(bundleID)", .containers),
                ("Library/Saved Application State/\(bundleID).savedState", .savedState),
                ("Library/WebKit/\(bundleID)", .webData),
                ("Library/HTTPStorages/\(bundleID)", .webData),
                ("Library/HTTPStorages/\(bundleID).binarycookies", .webData),
                ("Library/Cookies/\(bundleID).binarycookies", .webData),
                ("Library/Autosave Information/\(bundleID)", .other),
                ("Library/SyncedPreferences/\(bundleID).plist", .preferences),
                ("Library/Caches/com.apple.nsurlsessiond/Downloads/\(bundleID)", .caches),
            ]
            for (relative, kind) in byID {
                add(home.appendingPathComponent(relative), kind, evidence, .bundleIdentifier)
            }

            // Group containers and per-host preferences use the identifier as a
            // prefix; require a dot boundary so "com.foo" cannot match "com.foobar".
            scanDirectory(home.appendingPathComponent("Library/Group Containers")) { url in
                if hasBundleBoundary(url.lastPathComponent, bundleID) {
                    add(url, .containers, "Group container for \(bundleID)", .bundleIdentifier)
                }
            }
            scanDirectory(home.appendingPathComponent("Library/Preferences/ByHost")) { url in
                if hasBundleBoundary(url.lastPathComponent, bundleID) {
                    add(url, .preferences, "Per-host preferences for \(bundleID)", .bundleIdentifier)
                }
            }
            scanDirectory(home.appendingPathComponent("Library/Containers")) { url in
                if hasBundleBoundary(url.lastPathComponent, bundleID) {
                    add(url, .containers, "Sandbox container derived from \(bundleID)", .bundleIdentifier)
                }
            }

            // Launch agents and daemons, including helper labels.
            for root in [
                home.appendingPathComponent("Library/LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchDaemons"),
            ] {
                scanDirectory(root) { url in
                    let file = url.lastPathComponent
                    guard file.hasSuffix(".plist") else { return }
                    let label = String(file.dropLast(6))
                    if label == bundleID || label.hasPrefix(bundleID + ".") {
                        add(url, .launchAgents, "Launch agent labelled \(label)", .bundleIdentifier)
                    }
                }
            }
        }

        // 2. Display-name paths. Lower confidence, so restricted to directories
        //    where a name collision is unlikely to be someone else's data.
        if nameIsUsable {
            let variants = nameVariants(name)
            for variant in variants {
                let evidence = "Directory named “\(variant)”"
                // A variant that still carries the app's whole name is a solid
                // match. A shortened one is not: "Microsoft Word" reduced to
                // "Microsoft" names a directory four other Office apps share.
                let confidence: Leftover.Confidence =
                    variant.count >= name.count ? .exactName : .derivedName
                let byName: [(String, Leftover.Kind)] = [
                    ("Library/Application Support/\(variant)", .support),
                    ("Library/Caches/\(variant)", .caches),
                    ("Library/Logs/\(variant)", .logs),
                    ("Library/Preferences/\(variant).plist", .preferences),
                    ("Library/Saved Application State/\(variant).savedState", .savedState),
                    ("Library/Services/\(variant).workflow", .plugins),
                    ("Library/QuickLook/\(variant).qlgenerator", .plugins),
                    ("Library/Internet Plug-Ins/\(variant).plugin", .plugins),
                    ("Library/PreferencePanes/\(variant).prefPane", .plugins),
                    ("Library/Screen Savers/\(variant).saver", .plugins),
                    ("Library/Spotlight/\(variant).mdimporter", .plugins),
                    ("Library/Audio/Plug-Ins/Components/\(variant).component", .plugins),
                    ("Library/Audio/Plug-Ins/VST/\(variant).vst", .plugins),
                    ("Library/Audio/Plug-Ins/VST3/\(variant).vst3", .plugins),
                    ("Library/Contextual Menu Items/\(variant).plugin", .plugins),
                ]
                for (relative, kind) in byName {
                    add(home.appendingPathComponent(relative), kind, evidence, confidence)
                }
            }

            // Dotfile directories, lowercase only. These belong to CLI tools as
            // often as GUI apps, so they are reported but never preselected.
            let lower = name.lowercased().replacingOccurrences(of: " ", with: "")
            if lower.count >= 4, !ambiguousNames.contains(lower) {
                for relative in ["\(lower)", ".config/\(lower)", ".cache/\(lower)", ".local/share/\(lower)"] {
                    let candidate =
                        relative.hasPrefix(".")
                        ? home.appendingPathComponent(relative)
                        : home.appendingPathComponent(".\(relative)")
                    add(candidate, .support, "Dotfile directory matching “\(lower)”")
                }
            }
        }

        // 3. System-level support directories.
        if nameIsUsable {
            for (root, kind) in [
                ("/Library/Application Support", Leftover.Kind.support),
                ("/Library/Caches", .caches),
                ("/Library/Logs", .logs),
            ] {
                add(
                    URL(fileURLWithPath: root).appendingPathComponent(name),
                    kind,
                    "System-wide directory named “\(name)”"
                )
            }
        }

        return UninstallPlan(
            app: app,
            bundle: app.url,
            leftovers: found.values.sorted { $0.bytes > $1.bytes },
            uninstallVerdict: uninstallVerdict(for: app),
            requiresAdmin: elevated.values.sorted { $0.bytes > $1.bytes }
        )
    }

    // MARK: - Matching helpers

    static func isReverseDNS(_ identifier: String) -> Bool {
        guard identifier.count >= 5 else { return false }
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return parts.allSatisfy { part in
            guard !part.isEmpty,
                part.first != "-",
                part.last != "-"
            else { return false }
            return part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// True when `candidate` equals `bundleID` or extends it at a dot boundary.
    static func hasBundleBoundary(_ candidate: String, _ bundleID: String) -> Bool {
        if candidate == bundleID { return true }
        guard candidate.hasPrefix(bundleID) else {
            // Group containers are often prefixed with a team identifier.
            if let range = candidate.range(of: "." + bundleID), range.upperBound == candidate.endIndex {
                return true
            }
            if candidate.hasSuffix(bundleID), candidate.count > bundleID.count {
                let index = candidate.index(candidate.endIndex, offsetBy: -bundleID.count - 1)
                return candidate[index] == "."
            }
            return false
        }
        let remainder = candidate.dropFirst(bundleID.count)
        return remainder.isEmpty || remainder.hasPrefix(".")
    }

    /// Release-channel suffixes vendors append to the same product's name.
    ///
    /// Stripping one of these is safe because the base name still identifies the
    /// same application from the same vendor — "Zed Nightly" really does keep
    /// data under "Zed".
    static let channelSuffixes = [
        "Nightly", "Beta", "Alpha", "Dev", "Canary", "Preview", "Insiders", "Insider",
        "Edge", "Stable", "Release", "RC", "LTS", "Developer Edition", "Technology Preview",
    ]

    static func nameVariants(_ name: String) -> [String] {
        guard isSafePathComponent(name) else { return [] }
        var variants = [name]
        if name.contains(" ") {
            variants.append(name.replacingOccurrences(of: " ", with: ""))
            variants.append(name.replacingOccurrences(of: " ", with: "-"))
            variants.append(name.replacingOccurrences(of: " ", with: "_"))
        }

        // Only a known release-channel suffix may be dropped.
        //
        // This used to take the first word of any multi-word name, which turned
        // "Microsoft Word" into "Microsoft" and pointed the uninstaller at
        // ~/Library/Caches/Microsoft — shared by Excel, Outlook, OneNote and
        // Teams. Uninstalling one Office app would have taken the others' data
        // with it. A vendor name is not an application name.
        for suffix in channelSuffixes {
            let tail = " " + suffix
            guard name.lowercased().hasSuffix(tail.lowercased()) else { continue }
            let base = String(name.dropLast(tail.count))
                .trimmingCharacters(in: .whitespaces)
            guard base.count >= 3 else { break }
            variants.append(base)
            if base.contains(" ") {
                variants.append(base.replacingOccurrences(of: " ", with: ""))
                variants.append(base.replacingOccurrences(of: " ", with: "-"))
            }
            break
        }

        return Array(Set(variants.filter(isSafePathComponent)))
    }

    static func isSafePathComponent(_ name: String) -> Bool {
        guard !name.isEmpty,
            name != ".",
            name != "..",
            !name.contains("/"),
            !name.contains("\\"),
            !name.contains("\0")
        else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func uninstallVerdict(for app: InstalledApp) -> PathGuard.Verdict {
        let pathVerdict = PathGuard.canUninstall(bundleID: app.bundleID, path: app.url)
        guard pathVerdict.isAllowed else { return pathVerdict }
        if app.source == .homebrew {
            return .refused(
                reason: "Managed by Homebrew. Use Homebrew to run the cask's reviewed uninstall hooks."
            )
        }
        return .allowed
    }

    private static func scanDirectory(_ url: URL, _ body: (URL) -> Void) {
        // Bounded because two of the callers below are `~/Library/Containers`
        // and `~/Library/Group Containers`, which macOS gates behind Full Disk
        // Access. An unguarded listing of either never returns.
        let contents = Guarded.run(budget: 3) {
            try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        }
        for child in (contents ?? nil) ?? [] { body(child) }
    }
}
