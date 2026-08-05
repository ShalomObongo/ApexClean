import ApexCore
import AppKit
import SwiftUI

/// Drives the first-run setup assistant.
///
/// The goal is that permissions are settled once, deliberately, at a moment the
/// user is expecting to be asked — rather than as a system dialog ambushing them
/// mid-scan. What it will not do is pretend macOS is more permissive than it is:
/// Full Disk Access and App Management cannot be requested by any application,
/// so those steps open the right Settings pane, explain the click, and then
/// watch for the result instead of claiming to have done it.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case howItWorks
        case permissions
        case ready

        var id: Int { rawValue }
    }

    @Published private(set) var step: Step = .welcome {
        didSet { Settings.setupStep = step.rawValue }
    }
    @Published private(set) var states: [Permission: PermissionState] = [:]
    /// The permission currently waiting on the user, so its row can show it.
    @Published private(set) var pending: Permission?
    /// Set once a Full Disk Access grant lands, because the running process
    /// keeps the access it started with.
    @Published private(set) var relaunchRequired = false
    /// True when this launch is a continuation of a setup that macOS
    /// interrupted, so the permissions step can say so rather than looking
    /// like it silently jumped.
    @Published private(set) var resumed = false
    @Published var includesPersonalFolders: Bool {
        didSet { Settings.includesPersonalFolders = includesPersonalFolders }
    }

    /// True when setup ran under a build macOS no longer recognises, so any
    /// grants it recorded are gone.
    let signatureChanged: Bool

    init() {
        includesPersonalFolders = Settings.includesPersonalFolders
        signatureChanged = Settings.setupSignatureChanged
        // Resume where the user was. Granting Full Disk Access relaunches the
        // app, so starting over would mean the assistant appears to forget the
        // work the moment it succeeds.
        let saved = Step(rawValue: Settings.setupStep) ?? .welcome
        if signatureChanged {
            Settings.prepareForChangedSignature()
            step = .welcome
            resumed = false
            states = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, .notDetermined) })
        } else {
            step = saved
            resumed = saved != .welcome
            refresh()
        }
    }

    func acknowledgeResume() {
        guard resumed else { return }
        withAnimation(Motion.enter) { resumed = false }
    }

    /// Starts setup over. The saved step is cleared by `Settings.resetSetup()`,
    /// but the model outlives a restart, so its own state has to be rewound too.
    func restart() {
        step = .welcome
        resumed = false
        relaunchRequired = false
        pending = nil
        refresh()
    }

    var isFirstStep: Bool { step == .welcome }
    var isLastStep: Bool { step == .ready }

    var progress: Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    func state(of permission: Permission) -> PermissionState {
        states[permission] ?? .notDetermined
    }

    var grantedCount: Int {
        Permission.allCases.filter { state(of: $0).isGranted }.count
    }

    /// Re-reads every permission from macOS.
    ///
    /// Only permissions the user has already been asked about are probed;
    /// probing an undecided one would raise a dialog they did not initiate,
    /// which is the exact behaviour this whole flow exists to avoid.
    func refresh() {
        let asked = Settings.askedPermissions
        var next: [Permission: PermissionState] = [:]
        for permission in Permission.allCases {
            next[permission] = Permissions.state(
                of: permission,
                allowingProbe: asked.contains(permission)
            )
        }
        states = next
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        withAnimation(Motion.enter) { step = next }
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(Motion.enter) { step = previous }
    }

    func finish() {
        Settings.hasCompletedSetup = true
        NotificationCenter.default.post(name: .onboardingDidFinish, object: nil)
    }

    /// Requests a single permission.
    ///
    /// Requestable ones raise the system dialog directly. The rest open
    /// Settings, and `refresh()` on reactivation picks up whatever the user did
    /// there — which is why this never reports a result it has not verified.
    func grant(_ permission: Permission) {
        pending = permission

        guard permission.isRequestable else {
            Permissions.openSettings(for: permission)
            Settings.markAsked(permission)
            return
        }

        Task {
            // Off the main thread: the request blocks until the dialog is
            // answered, and the window must stay alive while it is up.
            let result = await Self.requestOffMainThread(permission)

            Settings.markAsked(permission)
            if permission == .personalFolders, result.isGranted {
                includesPersonalFolders = true
            }

            withAnimation(Motion.enter) {
                states[permission] = result
                pending = nil
            }

            // A refusal is a legitimate answer, but people usually mean "not
            // from a dialog I did not expect" rather than "never", so point at
            // where the decision can be changed.
            if !result.isGranted { Permissions.openSettings(for: permission) }
        }
    }

    /// Walks the permissions that macOS lets an app ask for, one dialog at a
    /// time. The manual ones are deliberately excluded: opening several
    /// Settings panes in a row would just lose the user.
    func grantAllRequestable() {
        Task {
            for permission in Permission.allCases
            where permission.isRequestable && !state(of: permission).isGranted {
                pending = permission
                let result = await Self.requestOffMainThread(permission)

                Settings.markAsked(permission)
                if permission == .personalFolders, result.isGranted {
                    includesPersonalFolders = true
                }
                withAnimation(Motion.enter) { states[permission] = result }
            }
            pending = nil
        }
    }

    /// Runs a permission request on a thread of its own.
    ///
    /// Deliberately **not** `Task.detached`. This call blocks until the user
    /// answers a system dialog — up to five minutes — and detached tasks run on
    /// the shared cooperative pool, which is only as wide as the core count.
    /// Parking several of those would starve every other piece of Swift
    /// concurrency in the process, including the UI work that has to keep the
    /// window alive behind the dialog.
    private static func requestOffMainThread(_ permission: Permission) async -> PermissionState {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: Permissions.request(permission)) }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Called when the app regains focus, typically on the way back from
    /// System Settings.
    func refreshAfterReturn() {
        let wasGranted = state(of: .fullDisk).isGranted
        refresh()
        if !wasGranted, state(of: .fullDisk).isGranted {
            withAnimation(Motion.enter) { relaunchRequired = true }
        }
        pending = nil
    }

    func relaunch() {
        Permissions.relaunch()
    }
}

extension Notification.Name {
    static let onboardingDidFinish = Notification.Name("ApexCleanOnboardingDidFinish")
}
