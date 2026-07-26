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
        case .history: "Everything ApexClean touched"
        }
    }

    var symbol: String {
        switch self {
        case .smartCare: "sparkles"
        case .cleanup: "wand.and.rays"
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
        case .smartCare: Palette.jade
        case .cleanup: Palette.cyan
        case .applications: Color(hex: 0x8B7FF0)
        case .maintenance: Color(hex: 0xF5B841)
        case .spaceLens: Color(hex: 0xE86FC4)
        case .vitals: Color(hex: 0x59A5F5)
        case .history: Color(hex: 0x7A8798)
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
    lazy var maintenance = MaintenanceModel()
    lazy var space = SpaceModel(history: history)

    @Published var lastCleanSummary: OperationLog.Session?
    @Published var totalReclaimedEver: Int64 = 0

    init() {
        totalReclaimedEver = history.totalReclaimed()
        lastCleanSummary = history.recentSessions(limit: 1).first
    }

    func refreshHistory() {
        totalReclaimedEver = history.totalReclaimed()
        lastCleanSummary = history.recentSessions(limit: 1).first
    }

    func go(to destination: Destination) {
        withAnimation(Motion.enter) { self.destination = destination }
    }
}
