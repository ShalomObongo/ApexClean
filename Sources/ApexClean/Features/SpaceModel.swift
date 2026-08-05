@preconcurrency import ApexCore
import AppKit
import SwiftUI

@MainActor
final class SpaceModel: ObservableObject {
    @Published private(set) var root: SpaceNode?
    @Published private(set) var current: SpaceNode?
    @Published private(set) var isScanning = false
    @Published private(set) var scannedPaths = 0
    @Published private(set) var currentPath = ""
    @Published var hovered: SpaceNode?
    @Published var selected: SpaceNode?
    @Published private(set) var largeFiles: [LargeFileFinder.Match] = []
    @Published var scanRoot: URL = PathGuard.home
    /// Set when a scan was abandoned because a path stopped responding. The
    /// alternative — an honest-looking spinner that never ends — is the worst
    /// outcome, so this is surfaced plainly and offered a way forward.
    @Published private(set) var stalledPath: String?
    /// Folders that did not answer in time and were left out of the map.
    @Published private(set) var unreadablePaths: [String] = []
    /// Off by default so mapping Home never raises an unexpected consent
    /// dialog. Turning it on is a deliberate, explained choice, and persisted so
    /// it stays made.
    @Published var includesProtectedLocations = false {
        didSet {
            // The guard is what stops the sync below from bouncing: `didSet`
            // fires on every assignment, including one that changes nothing.
            guard oldValue != includesProtectedLocations else { return }
            Settings.includesPersonalFolders = includesProtectedLocations
            NotificationCenter.default.post(name: .privacyScopeDidChange, object: nil)
        }
    }
    /// Node ids currently being deleted, so their button can show it.
    @Published private(set) var removing: Set<String> = []
    /// Surfaced when a removal was refused or failed. Silence after a click on
    /// Silence after a destructive click is indistinguishable from a broken app.
    @Published var removalError: String?

    private var scanner: SpaceScanner?
    private let history: OperationLog

    /// Paths proven unresponsive during this launch. A retry skips them, which
    /// is what makes a stall recoverable rather than terminal.
    private var quarantined: Set<String> = []
    /// Distinguishes the scan the UI is waiting for from an older one that may
    /// still be wedged in the kernel and can never be stopped.
    private var generation = 0
    private var watchdog: DispatchSourceTimer?
    private var refreshGeneration = 0
    private var refreshScanner: SpaceScanner?
    private var refreshTimer: DispatchSourceTimer?
    private var isRefreshing = false
    private var needsRefresh = false

    /// Removals only. Scans deliberately do **not** run here: a scan that blocks
    /// forever inside `open()` would sit at the head of a serial queue and
    /// silently swallow every scan afterwards. Scans go to the global pool, so
    /// the worst case is one leaked thread rather than a dead feature.
    private let queue = DispatchQueue(label: "fit.apexclean.space", qos: .userInitiated)

    init(history: OperationLog) {
        self.history = history
    }

    var breadcrumb: [SpaceNode] { current?.breadcrumb ?? [] }

    var tiles: [SpaceNode] { current?.children ?? [] }

    func scan(_ url: URL? = nil) {
        guard !isScanning else { return }
        cancelRefresh()
        let target = url ?? scanRoot
        scanRoot = target
        isScanning = true
        scannedPaths = 0
        stalledPath = nil
        unreadablePaths = []
        root = nil
        current = nil
        selected = nil

        generation += 1
        let token = generation
        let scanner = SpaceScanner(
            includesProtectedLocations: includesProtectedLocations,
            skipping: quarantined
        )
        self.scanner = scanner
        let includesProtected = includesProtectedLocations
        let skipList = quarantined
        startWatchdog(for: scanner, token: token)
        let model = self

        DispatchQueue.global(qos: .userInitiated).async {
            // Same coalescing rationale as the cleanup scan: a large home folder
            // emits thousands of progress posts, far more than the display can
            // consume, and forwarding them all starves the main thread.
            var lastPublish = Date.distantPast
            let node = scanner.scan(root: target) { update in
                let now = Date()
                guard now.timeIntervalSince(lastPublish) >= 0.06 else { return }
                lastPublish = now
                DispatchQueue.main.async {
                    guard model.generation == token else { return }
                    model.scannedPaths = update.scannedPaths
                    model.currentPath = update.currentPath
                }
            }
            let large =
                scanner.isStopped
                ? []
                : LargeFileFinder.find(
                    in: target,
                    minimumBytes: 200_000_000,
                    limit: 60,
                    includesProtectedLocations: includesProtected,
                    skipping: skipList,
                    onVisit: { scanner.noteProgress($0.path) },
                    isCancelled: { scanner.isStopped }
                )
            DispatchQueue.main.async {
                // A superseded scan must not overwrite the live one, even if it
                // eventually finishes hours later.
                guard model.generation == token else { return }
                model.stopWatchdog()
                withAnimation(Motion.stage) {
                    model.root = node
                    model.current = node
                    model.largeFiles = large
                    model.unreadablePaths = scanner.unreadablePaths
                    model.isScanning = false
                }
                if model.needsRefresh {
                    model.needsRefresh = false
                    model.refreshAfterRemoval()
                }
            }
        }
    }

    /// Watches the scanner's heartbeat rather than a clock, so a genuinely slow
    /// folder is left alone while a wedged one is caught. Only a syscall that
    /// never returns can stop the heartbeat.
    private func startWatchdog(for scanner: SpaceScanner, token: Int) {
        stopWatchdog()
        var lastBeat = -1
        var quietTicks = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == token, self.isScanning else { return }
            let beat = scanner.heartbeat
            if beat == lastBeat {
                quietTicks += 1
                // Eight quiet ticks ≈ 24s, longer than the longest bounded
                // sub-operation (`du` has a 20-second budget).
                if quietTicks >= 8 {
                    self.abandonStalledScan(scanner, token: token)
                }
            } else {
                lastBeat = beat
                quietTicks = 0
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func abandonStalledScan(_ scanner: SpaceScanner, token: Int) {
        let path = scanner.stalledPath
        stopWatchdog()
        scanner.cancel()
        // The blocked thread cannot be recovered, so the scan is disowned
        // instead: bumping the generation makes any late result inert.
        generation += 1
        if !path.isEmpty { quarantined.insert(path) }
        withAnimation(Motion.stage) {
            stalledPath = path.isEmpty ? scanRoot.path : path
            isScanning = false
        }
        Log.engine.warning("Space Lens abandoned an unresponsive path: \(path, privacy: .public)")
    }

    /// Retries the last root with the unresponsive path excluded.
    func retryWithoutStalledPath() {
        stalledPath = nil
        scan(scanRoot)
    }

    func cancel() {
        scanner?.cancel()
        stopWatchdog()
        // Disown as well as cancel: if the thread is blocked it will never read
        // the flag, and the user pressed Stop expecting the UI to come back.
        generation += 1
        isScanning = false
        cancelRefresh()
    }

    /// A second click on an already-selected tile clears the selection, which
    /// is the only way back to the folder listing without moving the pointer
    /// to the dismiss control.
    func select(_ node: SpaceNode) {
        withAnimation(Motion.tactile) {
            selected = (selected == node) ? nil : node
        }
    }

    func drill(into node: SpaceNode) {
        guard node.hasChildren else {
            selected = node
            return
        }
        enter(node)
    }

    func navigate(to node: SpaceNode) {
        enter(node)
    }

    func ascend() {
        guard let parent = current?.parent else { return }
        enter(parent)
    }

    /// Hover is cleared alongside the move: the pointer has not moved, so the
    /// hover callback will not fire again, and a detail pane still describing
    /// a folder that just left the screen is simply wrong.
    private func enter(_ node: SpaceNode) {
        withAnimation(Motion.stage) {
            current = node
            selected = nil
            hovered = nil
        }
    }

    func revealInFinder(_ node: SpaceNode) {
        guard !node.isSynthetic else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func delete(_ node: SpaceNode) {
        guard !node.isSynthetic else {
            removalError = "This tile groups smaller items. Open it and choose a real file or folder."
            return
        }
        removalError = nil
        let historyRef = history
        let url = node.url
        let bytes = node.bytes
        removing.insert(node.id)
        let model = self
        queue.async {
            if let reason = historyRef.prepareForOperation() {
                DispatchQueue.main.async {
                    model.removing.remove(node.id)
                    model.removalError =
                        "Deletion did not start because History is unavailable: \(reason)"
                }
                return
            }
            let remover = Remover()
            // Space Lens operates on user-selected documents, so user roots are
            // allowed only after the dedicated irreversible confirmation.
            let outcome = remover.remove(
                [url],
                disposal: .delete,
                allowUserRoots: true,
                knownSizes: [url: bytes]
            )
            let session = historyRef.commitSession(
                title: "Deleted from Space Lens",
                entries: outcome.historyEntries
            )
            DispatchQueue.main.async {
                model.removing.remove(node.id)
                guard outcome.removed.contains(url) else {
                    model.removalError =
                        outcome.refused.first?.reason
                        ?? outcome.failed.first?.error
                        ?? "The item could not be deleted."
                    return
                }
                if !outcome.historyEntries.isEmpty, session == nil {
                    model.removalError =
                        "The item was deleted, but the History entry could not be written."
                }
                model.largeFiles.removeAll { $0.url == url }
                if model.selected == node { model.selected = nil }
                if model.hovered == node { model.hovered = nil }
                withAnimation(Motion.stage) {
                    if node.parent == nil {
                        model.root = nil
                        model.current = nil
                    } else {
                        node.parent?.prune(node)
                        model.objectWillChange.send()
                    }
                }
                model.refreshAfterRemoval()
            }
        }
    }

    func deleteLargeFile(_ match: LargeFileFinder.Match) {
        removalError = nil
        let historyRef = history
        let url = match.url
        removing.insert(url.path)
        let model = self
        queue.async {
            if let reason = historyRef.prepareForOperation() {
                DispatchQueue.main.async {
                    model.removing.remove(url.path)
                    model.removalError =
                        "Deletion did not start because History is unavailable: \(reason)"
                }
                return
            }
            let remover = Remover()
            let outcome = remover.remove(
                [url],
                disposal: .delete,
                allowUserRoots: true,
                knownSizes: [url: match.bytes]
            )
            let session = historyRef.commitSession(
                title: "Deleted large file",
                entries: outcome.historyEntries
            )
            DispatchQueue.main.async {
                model.removing.remove(url.path)
                guard outcome.removed.contains(url) else {
                    model.removalError =
                        outcome.refused.first?.reason
                        ?? outcome.failed.first?.error
                        ?? "The file could not be deleted."
                    return
                }
                if !outcome.historyEntries.isEmpty, session == nil {
                    model.removalError =
                        "The file was deleted, but the History entry could not be written."
                }
                withAnimation(Motion.enter) {
                    model.largeFiles.removeAll { $0.url == url }
                    if let node = model.root.flatMap({ model.findNode(url: url, in: $0) }) {
                        node.parent?.prune(node)
                        model.objectWillChange.send()
                    }
                }
                model.refreshAfterRemoval()
            }
        }
    }

    private func refreshAfterRemoval() {
        if isScanning || isRefreshing {
            needsRefresh = true
            return
        }
        isRefreshing = true
        refreshGeneration += 1
        let token = refreshGeneration
        let target = scanRoot
        let scanner = SpaceScanner(
            includesProtectedLocations: includesProtectedLocations,
            skipping: quarantined
        )
        refreshScanner = scanner
        let includesProtected = includesProtectedLocations
        let skipList = quarantined
        let model = self

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.refreshGeneration == token else { return }
            scanner.cancel()
            self.refreshGeneration += 1
            self.isRefreshing = false
            self.refreshScanner = nil
            self.refreshTimer = nil
        }
        timer.resume()
        refreshTimer = timer

        DispatchQueue.global(qos: .utility).async {
            let node = scanner.scan(root: target)
            let large =
                scanner.isStopped
                ? []
                : LargeFileFinder.find(
                    in: target,
                    minimumBytes: 200_000_000,
                    limit: 60,
                    includesProtectedLocations: includesProtected,
                    skipping: skipList,
                    isCancelled: { scanner.isStopped }
                )
            DispatchQueue.main.async {
                guard model.refreshGeneration == token, !scanner.isStopped else { return }
                model.refreshTimer?.cancel()
                model.refreshTimer = nil
                model.refreshScanner = nil
                model.isRefreshing = false
                let desiredCurrentURL = model.current?.url
                model.root = node
                model.current =
                    desiredCurrentURL.flatMap { model.findNode(url: $0, in: node) }
                    ?? node
                model.largeFiles = large
                model.unreadablePaths = scanner.unreadablePaths
                if model.needsRefresh {
                    model.needsRefresh = false
                    model.refreshAfterRemoval()
                }
            }
        }
    }

    private func cancelRefresh() {
        refreshGeneration += 1
        refreshScanner?.cancel()
        refreshScanner = nil
        refreshTimer?.cancel()
        refreshTimer = nil
        isRefreshing = false
        needsRefresh = false
    }

    private func findNode(url: URL, in node: SpaceNode?) -> SpaceNode? {
        guard let node else { return nil }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        if node.url.standardizedFileURL.resolvingSymlinksInPath() == target {
            return node
        }
        for child in node.children {
            if let match = findNode(url: target, in: child) { return match }
        }
        return nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = scanRoot
        panel.prompt = "Analyse"
        if panel.runModal() == .OK, let url = panel.url {
            scan(url)
        }
    }
}
