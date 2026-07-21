import AppKit
import Foundation

/// One discovered, removable item.
public struct CleanupItem: Identifiable, Hashable {
    public let id: String
    public let url: URL
    public let bytes: Int64
    public let fileCount: Int
    public let modified: Date?

    public var displayPath: String { Glob.display(url.path) }
    public var name: String { url.lastPathComponent }

    init(url: URL, bytes: Int64, fileCount: Int, modified: Date?) {
        self.id = url.path
        self.url = url
        self.bytes = bytes
        self.fileCount = fileCount
        self.modified = modified
    }
}

/// A rule's worth of findings, ready to present as one reviewable row.
public struct CleanupFinding: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let category: CleanupCategory
    public let risk: RiskLevel
    public var items: [CleanupItem]
    /// Apps that are running and own this data. Present means "quit first".
    public var blockedBy: [String]

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var fileCount: Int { items.reduce(0) { $0 + $1.fileCount } }
    public var isBlocked: Bool { !blockedBy.isEmpty }

    public static func == (lhs: CleanupFinding, rhs: CleanupFinding) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A whole category of findings.
public struct CleanupGroup: Identifiable, Hashable {
    public let id: String
    public let category: CleanupCategory
    public var findings: [CleanupFinding]

    public init(id: String, category: CleanupCategory, findings: [CleanupFinding]) {
        self.id = id
        self.category = category
        self.findings = findings
    }

    public var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }
    public var fileCount: Int { findings.reduce(0) { $0 + $1.fileCount } }
    public var highestRisk: RiskLevel { findings.map(\.risk).max() ?? .regenerable }

    public static func == (lhs: CleanupGroup, rhs: CleanupGroup) -> Bool {
        lhs.id == rhs.id && lhs.findings == rhs.findings
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct CleanupReport {
    public var groups: [CleanupGroup] = []
    public var scannedAt = Date()
    public var duration: TimeInterval = 0
    /// Rules abandoned because their location stopped responding — almost
    /// always a directory macOS wants explicit permission for.
    public var stalledRules: [String] = []

    public init() {}

    public var totalBytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }
    public var totalFiles: Int { groups.reduce(0) { $0 + $1.fileCount } }
    public var isEmpty: Bool { groups.allSatisfy { $0.findings.isEmpty } }
}

/// Walks the catalog, measures what actually exists, and refuses anything
/// `PathGuard` will not vouch for — so the review list never offers a user
/// something the engine would later decline to remove.
public final class CleanupScanner {
    public struct Progress {
        public var completed: Int
        public var total: Int
        public var currentTitle: String
        public var bytesFound: Int64
        public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }

        public init(completed: Int, total: Int, currentTitle: String, bytesFound: Int64) {
            self.completed = completed
            self.total = total
            self.currentTitle = currentTitle
            self.bytesFound = bytesFound
        }
    }

    private let minimumInterestingBytes: Int64
    /// When false, rules targeting Desktop/Documents/Downloads are skipped
    /// entirely so an automatic scan can never trigger a privacy prompt.
    private let includesProtectedLocations: Bool
    private var cancelled = false
    private let lock = NSLock()

    public init(
        minimumInterestingBytes: Int64 = 16_384,
        includesProtectedLocations: Bool = false
    ) {
        self.minimumInterestingBytes = minimumInterestingBytes
        self.includesProtectedLocations = includesProtectedLocations
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// - Parameter running: Captured on the main actor by the caller. The
    ///   scanner runs off the main thread and must never touch `NSWorkspace`.
    public func scan(
        categories: Set<CleanupCategory> = Set(CleanupCategory.allCases),
        running: RunningAppsSnapshot = RunningAppsSnapshot(),
        onProgress: ((Progress) -> Void)? = nil
    ) -> CleanupReport {
        reset()
        let started = Date()

        var rules = CleanupCatalog.all.filter { categories.contains($0.category) }
        if !includesProtectedLocations {
            // Expanding a glob under a protected folder — or under a
            // consent-gated service like Messages or Safari — is enough to make
            // macOS raise a dialog, and the thread then blocks until it is
            // answered. These are dropped before the filesystem is touched at
            // all, not filtered out afterwards.
            rules.removeAll { PrivacyAccess.requiresConsent($0.pattern.expandingTilde) }
        }
        // Rules with the most to reclaim tend to sit in the same few roots; keeping
        // catalog order means progress reads as a coherent sweep rather than a jumble.
        rules.sort { $0.category.rawValue < $1.category.rawValue }

        var findingsByCategory: [CleanupCategory: [CleanupFinding]] = [:]
        var bytesFound: Int64 = 0
        var stalled: [String] = []

        for (index, rule) in rules.enumerated() {
            if isCancelled { break }
            onProgress?(
                Progress(
                    completed: index,
                    total: rules.count,
                    currentTitle: rule.title,
                    bytesFound: bytesFound
                )
            )

            // A single unreadable location must never be able to stall the whole
            // scan. `open(2)` on a path macOS wants consent for blocks in the
            // kernel and cannot be interrupted, so the only robust defence is to
            // stop waiting on it and carry on.
            switch withBudget(Self.ruleBudget, { self.evaluate(rule, running: running) }) {
            case let .finished(finding):
                guard let finding else { continue }
                bytesFound += finding.bytes
                findingsByCategory[rule.category, default: []].append(finding)
            case .timedOut:
                Log.engine.notice("Skipped '\(rule.title, privacy: .public)' — location did not respond")
                stalled.append(rule.title)
            }
        }

        // Trash is measured directly rather than through a glob: its contents are
        // arbitrary user files, and it is removed with a different disposal.
        if categories.contains(.trash), !isCancelled, let trash = trashFinding() {
            findingsByCategory[.trash] = [trash]
        }

        var report = CleanupReport()
        report.scannedAt = Date()
        report.duration = Date().timeIntervalSince(started)
        report.stalledRules = stalled
        report.groups = CleanupCategory.allCases.compactMap { category in
            guard let findings = findingsByCategory[category], !findings.isEmpty else { return nil }
            return CleanupGroup(
                id: category.rawValue,
                category: category,
                findings: findings.sorted { $0.bytes > $1.bytes }
            )
        }

        onProgress?(
            Progress(
                completed: rules.count,
                total: rules.count,
                currentTitle: "Finished",
                bytesFound: report.totalBytes
            )
        )
        return report
    }

    /// Seconds any single rule may take before the scan gives up on it.
    /// Long enough for a genuinely large cache directory on a slow disk, short
    /// enough that an unforeseen blocked path costs a pause, not a hang.
    private static let ruleBudget: TimeInterval = 3

    private enum BudgetResult<T> {
        case finished(T)
        case timedOut
    }

    /// Runs `work` on a throwaway thread and abandons it if it overruns.
    ///
    /// The abandoned thread is left blocked in the kernel; it will unwind on its
    /// own if the syscall ever returns. That is a deliberate trade — leaking a
    /// parked thread is strictly better than freezing the application.
    private func withBudget<T>(
        _ seconds: TimeInterval,
        _ work: @escaping () -> T
    ) -> BudgetResult<T> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        Thread.detachNewThread {
            let value = work()
            box.set(value)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + seconds) == .success, let value = box.get() else {
            return .timedOut
        }
        return .finished(value)
    }

    private final class ResultBox<T> {
        private let lock = NSLock()
        private var value: T?

        func set(_ newValue: T) {
            lock.lock(); value = newValue; lock.unlock()
        }

        func get() -> T? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    // MARK: - Rule evaluation

    private func evaluate(_ rule: CleanupRule, running: RunningAppsSnapshot) -> CleanupFinding? {
        let matches = Glob.expand(rule.pattern)
        guard !matches.isEmpty else { return nil }

        let ageCutoff = rule.minimumAgeDays.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        var items: [CleanupItem] = []

        for url in matches {
            if isCancelled { break }
            guard PathGuard.evaluate(url).isAllowed else { continue }
            // A glob can expand onto a gated path even when the pattern itself
            // looked innocuous, and measuring one blocks in the kernel with no
            // deadline. Re-check every expanded match, not just the pattern.
            if !includesProtectedLocations, PrivacyAccess.requiresConsent(url.path) { continue }

            let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = attributes?.contentModificationDate
            if let cutoff = ageCutoff {
                guard let modified, modified < cutoff else { continue }
            }

            let measurement = FileSize.measure(url, isCancelled: { self.isCancelled })
            guard measurement.bytes > 0 else { continue }
            items.append(
                CleanupItem(
                    url: url,
                    bytes: measurement.bytes,
                    fileCount: measurement.fileCount,
                    modified: modified
                )
            )
        }

        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        guard total >= minimumInterestingBytes else { return nil }

        let blockers = rule.requiresQuit.compactMap { bundleID -> String? in
            guard running.contains(bundleID) else { return nil }
            return running.displayName(for: bundleID)
        }

        return CleanupFinding(
            id: rule.id,
            title: rule.title,
            category: rule.category,
            risk: rule.risk,
            items: items.sorted { $0.bytes > $1.bytes },
            blockedBy: blockers
        )
    }

    private func trashFinding() -> CleanupFinding? {
        let trash = PathGuard.home.appendingPathComponent(".Trash")
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: trash,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            ), !contents.isEmpty
        else { return nil }

        var items: [CleanupItem] = []
        for url in contents {
            if isCancelled { break }
            let measurement = FileSize.measure(url, isCancelled: { self.isCancelled })
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            items.append(
                CleanupItem(
                    url: url,
                    bytes: measurement.bytes,
                    fileCount: measurement.fileCount,
                    modified: modified
                )
            )
        }
        guard !items.isEmpty else { return nil }

        return CleanupFinding(
            id: "trash|contents",
            title: "Trash contents",
            category: .trash,
            risk: .noticeable,
            items: items.sorted { $0.bytes > $1.bytes },
            blockedBy: []
        )
    }
}

/// An immutable view of which apps are running.
///
/// `NSWorkspace` is main-thread affine, so a background scan must never query it
/// directly — doing so can block indefinitely. Callers capture a snapshot on the
/// main actor and hand it to the scanner.
public struct RunningAppsSnapshot: Sendable {
    /// Lower-cased bundle identifiers.
    public let identifiers: Set<String>
    /// Lower-cased bundle identifier → localised name.
    public let names: [String: String]

    public init(identifiers: Set<String> = [], names: [String: String] = [:]) {
        self.identifiers = identifiers
        self.names = names
    }

    public func contains(_ bundleID: String) -> Bool {
        identifiers.contains(bundleID.lowercased())
    }

    public func displayName(for bundleID: String) -> String {
        names[bundleID.lowercased()] ?? bundleID
    }
}

public enum RunningApps {
    /// Must be called from the main actor.
    @MainActor
    public static func snapshot() -> RunningAppsSnapshot {
        var identifiers = Set<String>()
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier?.lowercased() else { continue }
            identifiers.insert(bundleID)
            if let name = app.localizedName { names[bundleID] = name }
        }
        return RunningAppsSnapshot(identifiers: identifiers, names: names)
    }
}
