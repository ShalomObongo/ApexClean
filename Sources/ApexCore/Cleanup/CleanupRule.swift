import Foundation

/// The groups a scan result is organised into. Order is presentation order.
public enum CleanupCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case userCaches
    case appLogs
    case systemJunk
    case browserData
    case developerJunk
    case aiTools
    case leftovers
    case installers
    case trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .userCaches: "Application Caches"
        case .appLogs: "Logs & Diagnostics"
        case .systemJunk: "System Junk"
        case .browserData: "Browser Data"
        case .developerJunk: "Developer Artifacts"
        case .aiTools: "AI Tooling"
        case .leftovers: "Orphaned App Data"
        case .installers: "Installers & Archives"
        case .trash: "Trash"
        }
    }

    public var subtitle: String {
        switch self {
        case .userCaches: "Regenerable data apps rebuild on demand"
        case .appLogs: "Crash reports and diagnostic output"
        case .systemJunk: "Temporary files macOS no longer needs"
        case .browserData: "Shader, GPU and code caches — not history or logins"
        case .developerJunk: "Build products, package caches, simulator data"
        case .aiTools: "Model and CLI caches from AI development tools"
        case .leftovers: "Files belonging to apps you already removed"
        case .installers: "Disk images and packages you already installed"
        case .trash: "Items waiting to be permanently deleted"
        }
    }

    public var symbol: String {
        switch self {
        case .userCaches: "shippingbox"
        case .appLogs: "doc.text.magnifyingglass"
        case .systemJunk: "gearshape.2"
        case .browserData: "globe"
        case .developerJunk: "hammer"
        case .aiTools: "cpu"
        case .leftovers: "questionmark.folder"
        case .installers: "arrow.down.circle"
        case .trash: "trash"
        }
    }

    /// Categories enabled by default in Smart Care. Anything with a plausible
    /// "I might still want this" story is left for explicit opt-in.
    public var isDefaultSelected: Bool {
        switch self {
        case .userCaches, .appLogs, .systemJunk, .browserData: true
        case .developerJunk, .aiTools, .leftovers, .installers, .trash: false
        }
    }
}

/// How much explaining a group needs before someone approves it.
public enum RiskLevel: Int, Comparable, Codable, Sendable {
    /// Rebuilt automatically, no user-visible consequence.
    case regenerable = 0
    /// Rebuilt automatically, but the next launch is slower or re-downloads.
    case rebuildCost = 1
    /// Removes state a user may notice (signed-out sessions, cleared lists).
    case noticeable = 2

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .regenerable: "Regenerates automatically"
        case .rebuildCost: "Rebuilds on next launch"
        case .noticeable: "You may notice this"
        }
    }
}

/// A single cleanup target, expressed as a glob so one rule can cover every
/// browser profile or version directory.
public struct CleanupRule: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let pattern: String
    public let category: CleanupCategory
    public let risk: RiskLevel
    /// Bundle identifiers that must not be running for this rule to be safe.
    public let requiresQuit: [String]
    /// Only match entries last modified at least this many days ago.
    public let minimumAgeDays: Int?

    public init(
        _ title: String,
        _ pattern: String,
        _ category: CleanupCategory,
        risk: RiskLevel = .regenerable,
        requiresQuit: [String] = [],
        minimumAgeDays: Int? = nil
    ) {
        self.id = "\(category.rawValue)|\(pattern)"
        self.title = title
        self.pattern = pattern
        self.category = category
        self.risk = risk
        self.requiresQuit = requiresQuit
        self.minimumAgeDays = minimumAgeDays
    }
}
