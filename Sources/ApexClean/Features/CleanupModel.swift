import SwiftUI
import ApexCore

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
    /// consent, and an automatic scan is the wrong moment to ask.
    @Published var includesProtectedLocations = false
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

    /// Trash contents cannot be moved to the Trash again, so a selection made up
    /// solely of them is deleted outright. The confirmation sheet reads this so
    /// the promise shown to the user and the disposal actually used can't drift.
    var removalIsPermanent: Bool {
        let findings = selectedFindings
        return findings.count == 1 && findings.contains { $0.category == .trash }
    }

    /// What the selection breaks down into, largest first.
    var selectionBreakdown: [(category: CleanupCategory, bytes: Int64, files: Int)] {
        Dictionary(grouping: selectedFindings, by: \.category)
            .map { (category: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }, files: $0.value.reduce(0) { $0 + $1.fileCount }) }
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
        guard stage != .scanning else { return }
        scanner?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        stage = .scanning
        report = CleanupReport()
        selection = []
        lastOutcome = nil
        progress = .init(completed: 0, total: 1, currentTitle: "Preparing", bytesFound: 0)

        let scanner = CleanupScanner(includesProtectedLocations: includesProtectedLocations)
        self.scanner = scanner
        let categories = enabledCategories
        // NSWorkspace is main-actor only, so the snapshot is taken here and
        // handed to the background scan rather than queried from it.
        let running = RunningApps.snapshot()

        scanQueue.async { [weak self] in
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
                    guard let self, self.scanGeneration == generation else { return }
                    self.progress = update
                }
            }

            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                self.finishScan(result)
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
        scanner?.cancel()
        scanGeneration &+= 1
        stage = report.isEmpty ? .idle : .reviewing
    }

    // MARK: - Selection

    func toggle(_ finding: CleanupFinding) {
        guard !finding.isBlocked else { return }
        if selection.contains(finding.id) { selection.remove(finding.id) }
        else { selection.insert(finding.id) }
    }

    func toggle(group: CleanupGroup) {
        let state = selectionState(for: group)
        let ids = group.findings.filter { !$0.isBlocked }.map(\.id)
        if state.isOn {
            ids.forEach { selection.remove($0) }
        } else {
            ids.forEach { selection.insert($0) }
        }
    }

    func selectAll() {
        selection = Set(report.groups.flatMap(\.findings).filter { !$0.isBlocked }.map(\.id))
    }

    func selectNone() { selection = [] }

    func selectRecommended() {
        selection = Set(
            report.groups
                .filter { $0.category.isDefaultSelected }
                .flatMap(\.findings)
                .filter { !$0.isBlocked && $0.risk <= .rebuildCost }
                .map(\.id)
        )
    }

    // MARK: - Removal

    func clean() {
        let findings = selectedFindings
        guard !findings.isEmpty else { return }
        stage = .cleaning

        let urls = findings.flatMap { $0.items.map(\.url) }
        var knownSizes: [URL: Int64] = [:]
        for finding in findings {
            for item in finding.items { knownSizes[item.url] = item.bytes }
        }
        let permanent = removalIsPermanent
        let historyRef = history

        scanQueue.async { [weak self] in
            let remover = Remover(history: historyRef)
            let outcome = remover.remove(
                urls,
                disposal: permanent ? .delete : .trash,
                allowUserRoots: permanent,
                knownSizes: knownSizes
            )
            let session = historyRef.commitSession(title: "Cleanup")
            DispatchQueue.main.async {
                self?.finishClean(outcome, session: session)
            }
        }
    }

    private func finishClean(_ outcome: Remover.Outcome, session: OperationLog.Session?) {
        lastOutcome = outcome
        lastSession = session

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
        withAnimation(Motion.stage) {
            stage = report.isEmpty ? .idle : .reviewing
            lastOutcome = nil
        }
    }
}
