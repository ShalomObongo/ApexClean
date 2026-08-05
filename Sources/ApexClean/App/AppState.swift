import ApexCore
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
    case smartCare
    case cleanup
    case applications
    case maintenance
    case spaceLens
    case vitals
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartCare: "Smart Care"
        case .cleanup: "Cleanup"
        case .applications: "Applications"
        case .maintenance: "Maintenance"
        case .spaceLens: "Space Lens"
        case .vitals: "Vitals"
        case .history: "History"
        }
    }

    var subtitle: String {
        switch self {
        case .smartCare: "One pass, fully reviewable"
        case .cleanup: "Choose exactly what goes"
        case .applications: "Uninstall, update, startup"
        case .maintenance: "Bounded, explainable tasks"
        case .spaceLens: "See where storage went"
        case .vitals: "Live system condition"
        case .history: "Recent local operations"
        }
    }

    var symbol: String {
        switch self {
        case .smartCare: "scope"
        case .cleanup: "checklist"
        case .applications: "square.grid.2x2"
        case .maintenance: "wrench.adjustable"
        case .spaceLens: "square.grid.3x3.topleft.filled"
        case .vitals: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// ⌘1…⌘7. Direct page access is table stakes for a native Mac app, and it
    /// keeps the sidebar from being the only way to move.
    var shortcut: KeyEquivalent {
        switch self {
        case .smartCare: "1"
        case .cleanup: "2"
        case .applications: "3"
        case .maintenance: "4"
        case .spaceLens: "5"
        case .vitals: "6"
        case .history: "7"
        }
    }

    var tint: Color {
        switch self {
        case .smartCare: Palette.brick
        case .cleanup: Palette.info
        case .applications: Palette.seaSage
        case .maintenance: Palette.caution
        case .spaceLens: Color(hex: 0xA894B2)
        case .vitals: Palette.info
        case .history: Color(hex: 0x81909A)
        }
    }
}

/// Root coordinator. Owns the long-lived services and the pieces of state that
/// more than one screen needs to agree on.
@MainActor
final class AppState: ObservableObject {
    @Published var destination: Destination = .smartCare

    let vitals = VitalsMonitor()
    let history = OperationLog()

    lazy var cleanup = CleanupModel(history: history)
    lazy var applications = ApplicationsModel(history: history)
    lazy var maintenance = MaintenanceModel(history: history)
    lazy var space = SpaceModel(history: history)

    @Published var lastCleanSummary: OperationLog.Session?
    @Published var totalHandledEver: Int64 = 0

    /// Shown over everything until setup is finished or skipped.
    @Published var isOnboarding: Bool
    let onboarding = OnboardingModel()

    init() {
        isOnboarding = !Settings.hasCompletedSetup || Settings.setupSignatureChanged
        refreshHistory()

        // `self` is bound before the Task, not inside it. Swift 5.9 — which is
        // what the macOS 14 toolchain ships — rejects reading a weak binding
        // from concurrently-executing code, so unwrapping in the Task body
        // fails to compile on the oldest supported OS.
        NotificationCenter.default.addObserver(
            forName: .onboardingDidFinish, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                withAnimation(Motion.stage) { self.isOnboarding = false }
                self.applyPrivacyPreference()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .privacyScopeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.applyPrivacyPreference()
            }
        }

        NotificationCenter.default.addObserver(
            forName: OperationLog.didChange, object: history, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshHistory() }
        }

        applyPrivacyPreference()
    }

    /// Pushes the persisted scan scope into the models that act on it.
    ///
    /// Both Cleanup and Space Lens own the same preference, so a change made in
    /// one has to reach the other: without this, including Downloads from Smart
    /// Care left Space Lens still skipping them until the next launch.
    ///
    /// These used to default to "excluded" on every launch, so a user who had
    /// opted into their personal folders silently got a narrower scan every
    /// time the app restarted.
    func applyPrivacyPreference() {
        let included = Settings.includesPersonalFolders
        cleanup.includesProtectedLocations = included
        space.includesProtectedLocations = included
    }

    /// Re-runs setup on demand.
    func restartOnboarding() {
        Settings.resetSetup()
        onboarding.restart()
        withAnimation(Motion.stage) { isOnboarding = true }
    }

    func refreshHistory() {
        let history = history
        Task.detached(priority: .utility) {
            let total = history.totalProcessed()
            let latest = history.recentSessions(limit: 1).first
            await MainActor.run {
                self.totalHandledEver = total
                self.lastCleanSummary = latest
            }
        }
    }

    func go(to destination: Destination) {
        withAnimation(Motion.enter) { self.destination = destination }
    }

    var hasDestructiveWorkInFlight: Bool {
        cleanup.stage == .cleaning
            || applications.isUninstalling
            || !applications.removingStartupItems.isEmpty
            || !applications.upgrading.isEmpty
            || !space.removing.isEmpty
            || maintenance.isRunning
    }
}
