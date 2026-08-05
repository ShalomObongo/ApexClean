import ApexCore
import Foundation
import Security

/// Preferences that must survive quitting the app.
///
/// The permissions themselves are held by macOS, not here — TCC is the source
/// of truth and this only records what the user has already been asked, so the
/// app can tell "not granted" apart from "never offered" and avoid asking twice.
///
/// One wrinkle worth stating plainly: macOS keys privacy grants to an app's
/// code signature. A Developer ID signature is stable across versions, so grants
/// survive updates. An ad-hoc signature — what a local `make app` produces —
/// changes on every build, and macOS treats each build as a different app. The
/// signature is therefore recorded alongside the setup state, so a rebuild is
/// reported honestly instead of showing stale permissions that no longer apply.
@MainActor
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let completedSetup = "setup.completed"
        static let setupSignature = "setup.signature"
        static let setupStep = "setup.step"
        static let askedPermissions = "setup.askedPermissions"
        static let includesPersonalFolders = "privacy.includesPersonalFolders"
    }

    // MARK: - Scan scope

    /// Whether Desktop, Documents and Downloads are included in scans.
    ///
    /// Persisted so the choice is made once. Previously this reset on every
    /// launch, quietly narrowing scans for anyone who had opted in.
    static var includesPersonalFolders: Bool {
        get { defaults.bool(forKey: Key.includesPersonalFolders) }
        set { defaults.set(newValue, forKey: Key.includesPersonalFolders) }
    }

    // MARK: - Setup

    static var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: Key.completedSetup) }
        set {
            defaults.set(newValue, forKey: Key.completedSetup)
            if newValue { defaults.set(currentSignature, forKey: Key.setupSignature) }
        }
    }

    /// True when setup ran against a build macOS no longer recognises as this
    /// app, which means every grant from that run has been discarded.
    static var setupSignatureChanged: Bool {
        guard hasCompletedSetup else { return false }
        guard let recorded = defaults.string(forKey: Key.setupSignature) else { return false }
        let current = currentSignature
        if recorded == current { return false }
        // Releases before 1.5 stored "version+build". A stable Team-ID
        // signature survives updates in TCC, so migrate without forcing a
        // permission walkthrough merely because the storage format improved.
        if recorded.contains("+"), current.contains("|team:") {
            defaults.set(current, forKey: Key.setupSignature)
            return false
        }
        return true
    }

    /// How far the user got in setup.
    ///
    /// This exists because granting Full Disk Access **quits the app**: macOS
    /// offers "Quit & Reopen" the moment the switch is flipped, and the running
    /// process would keep its old access either way. Without this, the one
    /// permission that costs the most effort is also the one that throws the
    /// user back to the welcome screen — punishing exactly the behaviour the
    /// assistant just asked for.
    static var setupStep: Int {
        get { defaults.integer(forKey: Key.setupStep) }
        set { defaults.set(newValue, forKey: Key.setupStep) }
    }

    /// Permissions the user has already been shown a dialog for. Only these are
    /// safe to probe on launch: probing an undecided one would raise a prompt
    /// nobody asked for.
    static var askedPermissions: Set<Permission> {
        get {
            let raw = defaults.stringArray(forKey: Key.askedPermissions) ?? []
            return Set(raw.compactMap(Permission.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.askedPermissions)
        }
    }

    /// Serialises the read-modify-write below.
    ///
    /// `UserDefaults` is thread-safe per access, not across a get/set pair, and
    /// this is called from whatever thread finished a permission request. A
    /// lost update would record a permission as never-asked, and the next
    /// launch would probe it — raising a consent dialog the user never asked
    /// for, which is the exact thing the setup assistant exists to prevent.
    private static let askedLock = NSLock()

    static func markAsked(_ permission: Permission) {
        askedLock.lock()
        defer { askedLock.unlock() }
        askedPermissions.insert(permission)
    }

    /// Forgets the setup record so the assistant can be run again from scratch.
    static func resetSetup() {
        defaults.removeObject(forKey: Key.completedSetup)
        defaults.removeObject(forKey: Key.setupSignature)
        defaults.removeObject(forKey: Key.setupStep)
        defaults.removeObject(forKey: Key.askedPermissions)
    }

    static func prepareForChangedSignature() {
        defaults.set(false, forKey: Key.completedSetup)
        defaults.set(currentSignature, forKey: Key.setupSignature)
        defaults.removeObject(forKey: Key.setupStep)
        defaults.removeObject(forKey: Key.askedPermissions)
    }

    /// Identifies this specific build to macOS's privacy database.
    ///
    /// A stable Team ID survives ordinary updates; an ad-hoc code-directory
    /// hash changes with the binary, matching the identity TCC actually sees.
    /// Version/build is retained only as a fallback if Security cannot inspect
    /// the running code.
    private static var currentSignature: String {
        if let signingIdentity { return signingIdentity }
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)+\(build)"
    }

    private static var signingIdentity: String? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
            let dynamicCode
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }

        var raw: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &raw
            ) == errSecSuccess,
            let info = raw as? [String: Any],
            let identifier = info[kSecCodeInfoIdentifier as String] as? String
        else { return nil }

        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        {
            return "\(identifier)|team:\(team)"
        }
        guard let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "\(identifier)|adhoc:" + unique.map { String(format: "%02x", $0) }.joined()
    }
}

extension Notification.Name {
    /// Posted when the Downloads/Desktop/Documents scan scope changes, so every
    /// model that holds a copy can re-read it.
    static let privacyScopeDidChange = Notification.Name("ApexCleanPrivacyScopeDidChange")
}
