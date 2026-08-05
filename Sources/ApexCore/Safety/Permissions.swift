import AppKit
import ApplicationServices
import Foundation

/// The macOS privacy permissions ApexClean can make use of, and honest answers
/// about which of them a program is actually allowed to ask for.
///
/// macOS splits these into two groups, and the difference drives the whole
/// onboarding design:
///
/// - **Requestable.** Touching the resource raises a system dialog. Personal
///   folders and Apple Events work this way, so the app can ask directly.
/// - **Manual only.** Full Disk Access and App Management have no request API
///   at all, by design — they are too powerful to be handed over from a dialog
///   the user did not go looking for. The best any app can do is open the right
///   Settings pane and explain what to click.
///
/// Nothing here promises more than the platform allows. An onboarding flow that
/// claimed to "grant everything" would simply be lying about the second group.
public enum Permission: String, CaseIterable, Identifiable, Codable, Sendable {
    case fullDisk
    case personalFolders
    case automation
    case appManagement

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullDisk: "Full Disk Access"
        case .personalFolders: "Desktop, Documents and Downloads"
        case .automation: "Finder automation"
        case .appManagement: "App Management"
        }
    }

    /// What the permission buys. Phrased as capability, never as pressure.
    public var purpose: String {
        switch self {
        case .fullDisk:
            "Measure the Trash, size sandbox containers during an uninstall, and reach caches macOS keeps private."
        case .personalFolders:
            "Find installers and forgotten downloads, and include these folders when mapping storage."
        case .automation:
            "Ask Finder to empty the Trash on your behalf."
        case .appManagement:
            "Replace an application in place when you install an update."
        }
    }

    /// What happens without it. The app is fully usable in every case, and
    /// saying so is what makes the request trustworthy rather than coercive.
    public var consequence: String {
        switch self {
        case .fullDisk:
            "Without it the Trash shows as unreadable and some folders report “Size unknown”. Everything else works."
        case .personalFolders:
            "Without it these folders are skipped entirely. No scan will ever read them."
        case .automation:
            "Without it emptying the Trash is left to you."
        case .appManagement:
            "Without it an update may be blocked and you finish it manually."
        }
    }

    /// Whether the app can raise the system dialog itself.
    public var isRequestable: Bool {
        switch self {
        case .personalFolders, .automation: true
        case .fullDisk, .appManagement: false
        }
    }

    /// Whether ApexClean's core value survives without it.
    public var isOptional: Bool {
        switch self {
        case .fullDisk, .personalFolders, .automation, .appManagement: true
        }
    }

    /// A newly granted Full Disk Access only applies to a freshly launched
    /// process, which is why macOS itself offers to quit and reopen.
    public var requiresRelaunch: Bool { self == .fullDisk }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .fullDisk: anchor = "Privacy_AllFiles"
        case .personalFolders: anchor = "Privacy_FilesAndFolders"
        case .automation: anchor = "Privacy_Automation"
        case .appManagement: anchor = "Privacy_SystemPolicyAppBundles"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

public enum PermissionState: String, Codable, Sendable {
    case granted
    case denied
    /// Never asked. Probing would raise a dialog.
    case notDetermined
    /// macOS exposes no way to find out.
    case unknown

    public var isGranted: Bool { self == .granted }
}

public enum Permissions {
    /// How long a *passive* read may take before it is treated as a stall.
    ///
    /// A status row is not worth freezing the interface over, so a read that
    /// has not answered by now is abandoned and reported as inaccessible.
    private static let probeBudget: TimeInterval = 3

    /// How long a *requested* read may take.
    ///
    /// This one is expected to block: macOS parks the read inside the kernel
    /// until the consent dialog is answered, so the clock is really measuring
    /// how long a person takes to read three prompts and click. Timing that out
    /// at probe speed would report "Not granted" to someone who just granted
    /// it, and then send them to System Settings to fix a problem they do not
    /// have. The bound stays only so a dialog nobody answers cannot wedge the
    /// setup assistant forever.
    private static let consentBudget: TimeInterval = 300

    /// The current state, **without ever raising a dialog**.
    ///
    /// `allowingProbe` exists because personal-folder access can only be
    /// discovered by attempting a read, and that read prompts when no decision
    /// has been recorded yet. Pass `true` only once the user has already been
    /// asked, when the answer is on file and the read returns silently.
    public static func state(
        of permission: Permission, allowingProbe: Bool = false
    )
        -> PermissionState
    {
        switch permission {
        case .fullDisk:
            return fullDiskState()
        case .automation:
            return automationState()
        case .personalFolders:
            // Full Disk Access subsumes these, so a granted disk means granted
            // folders without touching them.
            if fullDiskState() == .granted { return .granted }
            guard allowingProbe else { return .notDetermined }
            return personalFoldersState()
        case .appManagement:
            // No public API reports this. Claiming otherwise would be a guess
            // presented as a fact.
            return .unknown
        }
    }

    /// Asks macOS for the permission, raising the system dialog if one is due.
    ///
    /// Returns the resulting state. For permissions macOS does not let an app
    /// request, this opens the relevant Settings pane instead and reports the
    /// state unchanged.
    @discardableResult
    public static func request(_ permission: Permission) -> PermissionState {
        switch permission {
        case .personalFolders:
            return personalFoldersState(budget: consentBudget)
        case .automation:
            return automationState(askingIfNeeded: true)
        case .fullDisk, .appManagement:
            return state(of: permission)
        }
    }

    public static func snapshot(allowingProbe: Bool = false) -> [Permission: PermissionState] {
        var result: [Permission: PermissionState] = [:]
        for permission in Permission.allCases {
            result[permission] = state(of: permission, allowingProbe: allowingProbe)
        }
        return result
    }

    @MainActor
    public static func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Relaunches ApexClean so a new Full Disk Access grant takes effect.
    ///
    /// TCC decisions are read when a process starts, so the running instance
    /// keeps the access it had at launch no matter what changed since.
    @MainActor
    public static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            guard application != nil, error == nil else {
                if let error {
                    Log.safety.error(
                        "Could not relaunch ApexClean: \(error.localizedDescription, privacy: .public)"
                    )
                }
                return
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Probes

    /// Reads a file only Full Disk Access can open.
    ///
    /// TCC does not prompt for this one: without the grant the open simply
    /// fails, which makes it safe to call at any time. It is still bounded,
    /// because a denied read on a protected volume can block rather than
    /// return, and a permission check must never be the thing that hangs.
    private static func fullDiskState() -> PermissionState {
        let candidates = [
            PathGuard.home.appendingPathComponent(
                "Library/Application Support/com.apple.TCC/TCC.db"
            ),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
        ]

        let result = Guarded.run(budget: 2) { () -> PermissionState in
            for url in candidates where FileManager.default.fileExists(atPath: url.path) {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return .denied }
                try? handle.close()
                return .granted
            }
            // Neither probe file exists, which is not something a healthy macOS
            // install does. Reporting "denied" would be a guess.
            return .unknown
        }

        return result ?? .denied
    }

    private static func personalFoldersState(
        budget: TimeInterval = probeBudget
    )
        -> PermissionState
    {
        // Every scope is evaluated, deliberately. Short-circuiting on the first
        // refusal would mean a user who declines Downloads is never offered
        // Desktop or Documents at all, and the setup assistant is the one place
        // they are expecting to be asked.
        let results = PrivacyAccess.Scope.allCases.map { scope in
            Guarded.run(budget: budget) { PrivacyAccess.isReadable(scope) } ?? false
        }
        // Partial access is still a limitation the user has to act on, so it is
        // reported the same way as none: the row's job is to say whether the
        // feature will work, not to grade the grant.
        return results.allSatisfy { $0 } ? .granted : .denied
    }

    /// Asks the Apple Event manager directly rather than sending a test event.
    ///
    /// With `askUserIfNeeded` false this reports the recorded decision without
    /// showing anything, which is what makes an accurate status row possible
    /// before the user has agreed to anything.
    private static func automationState(askingIfNeeded: Bool = false) -> PermissionState {
        var target = AEAddressDesc()
        let identifier = Array("com.apple.finder".utf8)

        guard
            AECreateDesc(
                typeApplicationBundleID, identifier, identifier.count, &target
            ) == noErr
        else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, askingIfNeeded
        )

        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        // -1744. Returned only when asking was declined, so nothing was shown.
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .notDetermined
        default: return .unknown
        }
    }
}
