@preconcurrency import ApexCore
import SwiftUI

/// Drives scanning and selection for both Smart Care and Cleanup.
///
/// Selection lives here at *finding* granularity rather than per file, because
/// approving "Chrome shader cache" is a decision a person can actually make;
/// approving four hundred individual files is not.
@MainActor
final class CleanupModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case scanning
        case reviewing
        case cleaning
        case finished
    }

    @Published private(set) var stage: Stage = .idle
    /// Groups withheld at the moment Clean was pressed because their app had
    /// been launched since the scan. Surfaced so the withholding is visible
    /// rather than looking like the selection was silently ignored.
    @Published private(set) var blockedAtCleanTime = 0
    @Published private(set) var report = CleanupReport()
    @Published private(set) var progress = CleanupScanner.Progress(
        completed: 0, total: 1, currentTitle: "", bytesFound: 0
    )
    @Published var selection: Set<String> = []
    @Published var expandedGroups: Set<String> = []
    @Published private(set) var lastOutcome: Remover.Outcome?
    @Published private(set) var lastSession: OperationLog.Session?
    @Published var enabledCategories: Set<CleanupCategory> = Set(CleanupCategory.allCases)
    @Published var focusedCategory: String?
    /// Off by default: including Downloads and Desktop makes macOS ask for
    /// consent, and an automatic scan is the wrong moment to ask. Persisted, so
    /// opting in is a decision made once rather than every launch.
    @Published var includesProtectedLocations = false {
        didSet {
            // The guard is what stops the sync below from bouncing: `didSet`
            // fires on every assignment, including one that changes nothing.
            guard oldValue != includesProtectedLocations else { return }
            Settings.includesPersonalFolders = includesProtectedLocations
            NotificationCenter.default.post(name: .privacyScopeDidChange, object: nil)
        }
    }
    @Published private(set) var protectedScopesGranted: Set<String> = []

    private let history: OperationLog
    private var scanner: CleanupScanner?
    /// A dedicated queue, not the Swift concurrency pool.
    ///
    /// Scanning is blocking file I/O, and blocking a cooperative-pool thread can
    /// starve the runtime that the progress updates themselves depend on — the
    /// UI then freezes precisely when it should be most alive.
    private let scanQueue = DispatchQueue(label: "fit.apexclean.scan", qos: .userInitiated)
    private var scanGeneration = 0

    init(history: OperationLog) {
        self.history = history
    }

    // MARK: - Derived state

    var selectedFindings: [CleanupFinding] {
        report.groups.flatMap(\.findings).filter { selection.contains($0.id) && !$0.isBlocked }
    }

    var selectedBytes: Int64 { selectedFindings.reduce(0) { $0 + $1.bytes } }
    var selectedFileCount: Int { selectedFindings.reduce(0) { $0 + $1.fileCount } }

    /// What the selection breaks down into, largest first.
    var selectionBreakdown: [(category: CleanupCategory, bytes: Int64, files: Int)] {
        Dictionary(grouping: selectedFindings, by: \.category)
            .map {
                (
                    category: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes },
                    files: $0.value.reduce(0) { $0 + $1.fileCount }
                )
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Findings the user ticked that are held open by a running app. These are
    /// excluded from `selectedFindings`, so the sheet must say so out loud
    /// rather than let the total quietly come up short.
    var skippedBlockedFindings: [CleanupFinding] {
        report.groups.flatMap(\.findings).filter { selection.contains($0.id) && $0.isBlocked }
    }

    var dialSegments: [(id: String, bytes: Int64)] {
        report.groups
            .filter { $0.bytes > 0 }
            .map { (id: $0.category.rawValue, bytes: $0.bytes) }
    }

    var blockedFindings: [CleanupFinding] {
        report.groups.flatMap(\.findings).filter(\.isBlocked)
    }

    func selectionState(for group: CleanupGroup) -> (isOn: Bool, isMixed: Bool) {
        let selectable = group.findings.filter { !$0.isBlocked }
        guard !selectable.isEmpty else { return (false, false) }
        let selected = selectable.filter { selection.contains($0.id) }.count
        if selected == 0 { return (false, false) }
        if selected == selectable.count { return (true, false) }
        return (false, true)
    }

    // MARK: - Scanning

    func scan() {
        guard stage != .scanning, stage != .cleaning else { return }
        scanner?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        stage = .scanning
        report = CleanupReport()
        selection = []
        lastOutcome = nil
        blockedAtCleanTime = 0
        progress = .init(completed: 0, total: 1, currentTitle: "Preparing", bytesFound: 0)

        let scanner = CleanupScanner(includesProtectedLocations: includesProtectedLocations)
        self.scanner = scanner
        let categories = enabledCategories
        // NSWorkspace is main-actor only, so the snapshot is taken here and
        // handed to the background scan rather than queried from it.
        let running = RunningApps.snapshot()
        let model = self

        scanQueue.async {
            // The scanner emits an update per rule — several hundred over a
            // couple of seconds. Forwarding every one would post a @Published
            // change (and a full SwiftUI re-render, with animated numeric
            // transitions) faster than the main thread can draw, which stalls
            // the very UI the progress is meant to animate. Coalescing to ~20/s
            // is well above the rate a person can perceive.
            let throttle: TimeInterval = 0.05
            var lastPublish = Date.distantPast

            let result = scanner.scan(categories: categories, running: running) { update in
                let now = Date()
                let isFinal = update.completed >= update.total
                guard isFinal || now.timeIntervalSince(lastPublish) >= throttle else { return }
                lastPublish = now
                DispatchQueue.main.async {
                    guard model.scanGeneration == generation else { return }
                    model.progress = update
                }
            }

            DispatchQueue.main.async {
                guard model.scanGeneration == generation else { return }
                model.finishScan(result)
            }
        }
    }

    private func finishScan(_ result: CleanupReport) {
        report = result
        // Preselect only what the catalog marks safe by default. Everything else
        // stays opt-in, so nothing surprising is ever queued for removal.
        selection = Set(
            result.groups
                .filter { $0.category.isDefaultSelected }
                .flatMap(\.findings)
                .filter { !$0.isBlocked && $0.risk <= .rebuildCost }
                .map(\.id)
        )
        expandedGroups = []
        withAnimation(Motion.stage) {
            stage = result.isEmpty ? .finished : .reviewing
        }
    }

    func cancelScan() {
        guard stage == .scanning else { return }
        scanner?.cancel()
        scanGeneration &+= 1
        stage = report.isEmpty ? .idle : .reviewing
    }

    // MARK: - Selection

    func toggle(_ finding: CleanupFinding) {
        guard stage == .reviewing, !finding.isBlocked else { return }
        if selection.contains(finding.id) {
            selection.remove(finding.id)
        } else {
            selection.insert(finding.id)
        }
    }

    func toggle(group: CleanupGroup) {
        guard stage == .reviewing else { return }
        let state = selectionState(for: group)
        let ids = group.findings.filter { !$0.isBlocked }.map(\.id)
        if state.isOn {
            ids.forEach { selection.remove($0) }
        } else {
            ids.forEach { selection.insert($0) }
        }
    }

    func selectAll() {
        guard stage == .reviewing else { return }
        selection = Set(report.groups.flatMap(\.findings).filter { !$0.isBlocked }.map(\.id))
    }

    func selectNone() {
        guard stage == .reviewing else { return }
        selection = []
    }

    func selectRecommended() {
        guard stage == .reviewing else { return }
        selection = Set(
            report.groups
                .filter { $0.category.isDefaultSelected }
                .flatMap(\.findings)
                .filter { !$0.isBlocked && $0.risk <= .rebuildCost }
                .map(\.id)
        )
    }

    func refreshRunningBlockers() {
        let running = RunningApps.snapshot()
        var groups = report.groups
        for groupIndex in groups.indices {
            for findingIndex in groups[groupIndex].findings.indices {
                let required = groups[groupIndex].findings[findingIndex].requiresQuit
                groups[groupIndex].findings[findingIndex].blockedBy = required.compactMap {
                    running.contains($0) ? running.displayName(for: $0) : nil
                }
            }
        }
        report.groups = groups
    }

    // MARK: - Removal

    func clean() {
        guard stage == .reviewing else { return }
        let selection = selectedFindings
        guard !selection.isEmpty else { return }

        // Re-checked here, not reused from the scan.
        //
        // The scan's snapshot is taken before the user has seen anything, and
        // review is unbounded — they can read the list, launch the very app
        // whose caches are in it, and come back. Deleting a live Chromium's
        // Code Cache is a known cause of "your profile could not be opened
        // correctly" on next launch, and the sheet explicitly promises these
        // are held back while an app is running.
        let running = RunningApps.snapshot()
        let findings = selection.filter { finding in
            finding.requiresQuit.allSatisfy { !running.contains($0) }
        }
        let heldBack = selection.count - findings.count
        guard !findings.isEmpty else {
            stage = .reviewing
            blockedAtCleanTime = heldBack
            return
        }
        blockedAtCleanTime = heldBack
        stage = .cleaning

        let historyRef = history
        let model = self

        scanQueue.async {
            var outcome = Remover.Outcome()
            if let reason = historyRef.prepareForOperation() {
                outcome.failed.append(
                    (
                        historyRef.location,
                        "Cleanup did not start because History is unavailable: \(reason)"
                    )
                )
                let finalOutcome = outcome
                DispatchQueue.main.async {
                    model.finishClean(finalOutcome, session: nil, heldBack: heldBack)
                }
                return
            }

            var heldBackDuringRemoval = 0
            let runningLatch = OperationLatch()

            for finding in findings {
                if runningLatch.isSet { break }
                let live = DispatchQueue.main.sync { RunningApps.snapshot() }
                guard finding.requiresQuit.allSatisfy({ !live.contains($0) }) else {
                    heldBackDuringRemoval += 1
                    continue
                }

                let required = finding.requiresQuit
                let remover = Remover(
                    refusalBeforeDispose: { _ in
                        if runningLatch.isSet {
                            return "A protected app started running; the remaining cleanup was stopped"
                        }
                        let current = DispatchQueue.main.sync { RunningApps.snapshot() }
                        guard let identifier = required.first(where: current.contains) else {
                            return nil
                        }
                        runningLatch.set()
                        return
                            "\(current.displayName(for: identifier)) started running; this cleanup group was left untouched"
                    }
                )
                let urls = finding.items.map(\.url)
                let sizes = Dictionary(uniqueKeysWithValues: finding.items.map { ($0.url, $0.bytes) })
                let findingOutcome = remover.remove(
                    urls,
                    disposal: .delete,
                    allowUserRoots: false,
                    knownSizes: sizes,
                    stopAfterRefusal: true
                )
                if findingOutcome.removed.isEmpty,
                    !findingOutcome.refused.isEmpty,
                    !required.isEmpty
                {
                    heldBackDuringRemoval += 1
                }
                outcome.merge(findingOutcome)
            }
            let session = historyRef.commitSession(
                title: "Cleanup",
                entries: outcome.historyEntries
            )
            if !outcome.historyEntries.isEmpty, session == nil {
                outcome.failed.append(
                    (
                        historyRef.location,
                        "Files were deleted, but the History entry could not be written"
                    )
                )
            }
            let finalOutcome = outcome
            let totalHeldBack = heldBack + heldBackDuringRemoval
            DispatchQueue.main.async {
                model.finishClean(
                    finalOutcome,
                    session: session,
                    heldBack: totalHeldBack
                )
            }
        }

    }

    private func finishClean(
        _ outcome: Remover.Outcome,
        session: OperationLog.Session?,
        heldBack: Int
    ) {
        lastOutcome = outcome
        lastSession = session
        blockedAtCleanTime = heldBack
        if outcome.removed.isEmpty, !outcome.failed.isEmpty {
            withAnimation(Motion.stage) { stage = .reviewing }
            return
        }

        // Drop everything we removed so the review list reflects reality without
        // needing a full rescan.
        let removed = Set(outcome.removed.map(\.path))
        var groups: [CleanupGroup] = []
        for group in report.groups {
            var findings: [CleanupFinding] = []
            for var finding in group.findings {
                finding.items.removeAll { removed.contains($0.url.path) }
                if !finding.items.isEmpty { findings.append(finding) }
            }
            if !findings.isEmpty {
                groups.append(CleanupGroup(id: group.id, category: group.category, findings: findings))
            }
        }

        report.groups = groups
        selection = []

        withAnimation(Motion.stage) { stage = .finished }
    }

    func reset() {
        guard stage != .cleaning else { return }
        withAnimation(Motion.stage) {
            stage = report.isEmpty ? .idle : .reviewing
            lastOutcome = nil
        }
    }

    private final class OperationLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
