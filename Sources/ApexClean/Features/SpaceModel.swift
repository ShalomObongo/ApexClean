import ApexCore
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
    /// Node ids currently being moved to the Trash, so their button can show it.
    @Published private(set) var removing: Set<String> = []
    /// Surfaced when a removal was refused or failed. Silence after a click on
    /// "Move to Trash" is indistinguishable from a broken app.
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Same coalescing rationale as the cleanup scan: a large home folder
            // emits thousands of progress posts, far more than the display can
            // consume, and forwarding them all starves the main thread.
            var lastPublish = Date.distantPast
            let node = scanner.scan(root: target) { update in
                let now = Date()
                guard now.timeIntervalSince(lastPublish) >= 0.06 else { return }
                lastPublish = now
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.scannedPaths = update.scannedPaths
                    self.currentPath = update.currentPath
                }
            }
            let large = LargeFileFinder.find(
                in: target,
                minimumBytes: 200_000_000,
                limit: 60,
                includesProtectedLocations: includesProtected,
                skipping: skipList,
                onVisit: { scanner.noteProgress() },
                isCancelled: { scanner.isStopped }
            )
            DispatchQueue.main.async {
                // A superseded scan must not overwrite the live one, even if it
                // eventually finishes hours later.
                guard let self, self.generation == token else { return }
                self.stopWatchdog()
                withAnimation(Motion.stage) {
                    self.root = node
                    self.current = node
                    self.largeFiles = large
                    self.unreadablePaths = scanner.unreadablePaths
                    self.isScanning = false
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
                // Four quiet ticks ≈ 12s without touching a single path.
                if quietTicks >= 4 {
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
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func moveToTrash(_ node: SpaceNode) {
        let historyRef = history
        let url = node.url
        let bytes = node.bytes
        removing.insert(node.id)
        queue.async { [weak self] in
            let remover = Remover(history: historyRef)
            // Space Lens operates on real user documents, so the user-root guard
            // is relaxed here — but disposal is always the Trash, never unlink.
            let outcome = remover.remove(
                [url],
                disposal: .trash,
                allowUserRoots: true,
                knownSizes: [url: bytes]
            )
            _ = historyRef.commitSession(title: "Moved to Trash from Space Lens")
            DispatchQueue.main.async {
                guard let self else { return }
                self.removing.remove(node.id)
                guard outcome.removed.contains(url) else {
                    self.removalError =
                        outcome.refused.first?.reason
                        ?? outcome.failed.first?.error
                        ?? "The item could not be moved to the Trash."
                    return
                }
                self.largeFiles.removeAll { $0.url == url }
                if self.selected == node { self.selected = nil }
                if self.hovered == node { self.hovered = nil }
                // Prune in place rather than rescanning: re-measuring a home
                // folder takes minutes and the answer is already known.
                withAnimation(Motion.stage) {
                    node.parent?.prune(node)
                    self.objectWillChange.send()
                }
            }
        }
    }

    func trashLargeFile(_ match: LargeFileFinder.Match) {
        let historyRef = history
        let url = match.url
        removing.insert(url.path)
        queue.async { [weak self] in
            let remover = Remover(history: historyRef)
            let outcome = remover.remove(
                [url],
                disposal: .trash,
                allowUserRoots: true,
                knownSizes: [url: match.bytes]
            )
            _ = historyRef.commitSession(title: "Moved large file to Trash")
            DispatchQueue.main.async {
                guard let self else { return }
                self.removing.remove(url.path)
                guard outcome.removed.contains(url) else {
                    self.removalError =
                        outcome.refused.first?.reason
                        ?? outcome.failed.first?.error
                        ?? "The file could not be moved to the Trash."
                    return
                }
                withAnimation(Motion.enter) {
                    self.largeFiles.removeAll { $0.url == url }
                }
            }
        }
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
