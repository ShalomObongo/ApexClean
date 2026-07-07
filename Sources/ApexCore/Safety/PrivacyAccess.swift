import Foundation
import AppKit

/// Access checks for the directories macOS protects behind a privacy consent
/// prompt (Desktop, Documents, Downloads, and the wider Full Disk Access set).
///
/// The rule this module exists to enforce: **never touch a protected directory
/// as a side effect of something the user did not explicitly ask for.** Reading
/// one triggers a system consent dialog, and a maintenance app that throws
/// unexplained permission prompts at people during a routine scan has already
/// lost their trust.
///
/// So the automatic scan stays inside directories that need no consent, and
/// anything beyond that is offered as a deliberate, explained action.
public enum PrivacyAccess {
    public enum Scope: String, CaseIterable, Identifiable, Sendable {
        case downloads
        case desktop
        case documents

        public var id: String { rawValue }

        public var url: URL {
            switch self {
            case .downloads: PathGuard.home.appendingPathComponent("Downloads")
            case .desktop: PathGuard.home.appendingPathComponent("Desktop")
            case .documents: PathGuard.home.appendingPathComponent("Documents")
            }
        }

        public var title: String {
            switch self {
            case .downloads: "Downloads"
            case .desktop: "Desktop"
            case .documents: "Documents"
            }
        }

        /// What ApexClean would do with access, phrased so consenting is an
        /// informed decision rather than a reflex.
        public var purpose: String {
            switch self {
            case .downloads: "Find installers and half-finished downloads you no longer need."
            case .desktop: "Find installers left on the Desktop."
            case .documents: "Include Documents when mapping storage in Space Lens."
            }
        }
    }

    /// Whether the directory is readable *right now*.
    ///
    /// This deliberately performs a real read. macOS answers from the existing
    /// consent record when one exists, and only prompts when none does — which
    /// is why this must be called solely in response to a user action, never
    /// during an automatic scan.
    public static func isReadable(_ scope: Scope) -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: scope.url,
            includingPropertiesForKeys: nil,
            options: []
        )
        return contents != nil
    }

    /// Paths that sit behind Full Disk Access or a per-service consent prompt,
    /// even though they look like ordinary caches.
    ///
    /// This list is the reason the automatic scan does not stall: reading any of
    /// these without prior consent causes macOS to raise a dialog, and the
    /// calling thread then blocks *in the kernel* until it is answered. A
    /// background scan has no business doing that.
    private static var consentGatedPrefixes: [String] {
        let home = PathGuard.home.path
        return [
            "\(home)/Library/Messages",
            "\(home)/Library/Mail",
            "\(home)/Library/Safari",
            "\(home)/Library/Calendars",
            "\(home)/Library/Reminders",
            "\(home)/Library/Photos",
            "\(home)/Library/Cookies",
            "\(home)/Library/HomeKit",
            "\(home)/Library/IdentityServices",
            "\(home)/Library/Suggestions",
            "\(home)/Library/Application Support/AddressBook",
            "\(home)/Library/Application Support/CallHistoryDB",
            "\(home)/Library/Application Support/com.apple.TCC",
            "\(home)/Library/Caches/CloudKit",
        ] + mediaLibraryPrefixes
    }

    /// Media libraries, which macOS gates behind its own consent service
    /// (`kTCCServiceMediaLibrary`) rather than Full Disk Access.
    ///
    /// These live in plain-looking home folders, which is what makes them
    /// dangerous: `~/Music/Music` reads like an ordinary directory right up
    /// until the `open()` blocks in the kernel waiting for a dialog nobody is
    /// there to answer. Space Lens hung on exactly this path.
    private static var mediaLibraryPrefixes: [String] {
        let home = PathGuard.home.path
        return [
            "\(home)/Music/Music",
            "\(home)/Music/iTunes",
            "\(home)/Movies/TV",
            "\(home)/Pictures/Photos Library.photoslibrary",
        ]
    }

    /// Bundle-identifier prefixes whose caches macOS gates.
    ///
    /// Apple's own sandboxed containers are the big one: everything under
    /// `~/Library/Containers/com.apple.*` needs Full Disk Access, as do the
    /// media caches belonging to Music, TV, Podcasts and the App Store. These
    /// were found empirically — each one blocked a scan indefinitely.
    private static var gatedAppleCachePrefixes: [String] {
        [
            "com.apple.Music", "com.apple.TV", "com.apple.podcasts",
            "com.apple.AppStore", "com.apple.appstored", "com.apple.amp",
            "com.apple.AMPArtworkAgent", "com.apple.AppleMediaServices",
            "com.apple.itunescloud", "com.apple.photoanalysisd",
            "com.apple.mediaanalysisd", "com.apple.akd", "com.apple.parsecd",
            "com.apple.geod", "com.apple.mobilesync", "com.apple.iCloud",
            "com.apple.Safari", "com.apple.mail",
        ]
    }

    /// True when reading the path could trigger a consent dialog — either
    /// because it is inside a protected folder, or because it belongs to a
    /// service macOS gates individually.
    public static func requiresConsent(_ path: String) -> Bool {
        isProtected(path) || isConsentGatedService(path)
    }

    public static func isConsentGatedService(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = PathGuard.home.path

        if consentGatedPrefixes.contains(where: {
            standardized == $0 || standardized.hasPrefix($0 + "/")
        }) { return true }

        // Sandbox containers, both per-app and shared group containers.
        //
        // These are app-private stores that macOS puts behind Full Disk Access.
        // Without it, reads do not fail — they *block*, one folder at a time,
        // and a Mac has hundreds of them. Measured on a real machine this
        // turned a one-minute map into an hours-long crawl through storage no
        // user thinks of as their own files.
        for root in ["\(home)/Library/Containers", "\(home)/Library/Group Containers"]
        where standardized == root || standardized.hasPrefix(root + "/") {
            return true
        }

        // Apple media caches under ~/Library/Caches.
        let cacheRoot = "\(home)/Library/Caches/"
        if standardized.hasPrefix(cacheRoot) {
            let remainder = String(standardized.dropFirst(cacheRoot.count))
            return gatedAppleCachePrefixes.contains { remainder.hasPrefix($0) }
        }

        return false
    }

    /// True when a path lies inside a consent-protected user folder.
    public static func isProtected(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return Scope.allCases.contains { scope in
            let root = scope.url.path
            return standardized == root || standardized.hasPrefix(root + "/")
        }
    }

    /// Opens the relevant System Settings pane. Preferred over prompting,
    /// because it shows the user exactly what they are granting and to whom.
    @MainActor
    public static func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
