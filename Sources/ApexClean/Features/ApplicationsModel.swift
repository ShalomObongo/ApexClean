import SwiftUI
import ApexCore

@MainActor
final class ApplicationsModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case updates = "Updates"
        case startup = "Startup"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .installed
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var outdated: [HomebrewBridge.OutdatedCask] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCheckingUpdates = false
    @Published var search = ""
    @Published var sort: Sort = .size

    @Published private(set) var plan: UninstallPlan?
    @Published private(set) var isBuildingPlan = false
    @Published var planSelection: Set<String> = []
    @Published private(set) var uninstallOutcome: Remover.Outcome?
    @Published private(set) var isUninstalling = false

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size"
        case name = "Name"
        case lastUsed = "Last used"
        var id: String { rawValue }
    }

    private let history: OperationLog

    /// Dedicated queue for inventory work.
    ///
    /// `AppInventory` does blocking filesystem I/O, shells out to Homebrew, and
    /// measures bundles with `concurrentPerform`. None of that may run on the
    /// Swift concurrency cooperative pool: blocking calls occupy pool threads,
    /// and `concurrentPerform` from a cooperative thread can starve the runtime
    /// outright — which is exactly how this screen ended up showing nothing.
    private let queue = DispatchQueue(label: "fit.apexclean.apps", qos: .userInitiated)
    private var loadGeneration = 0

    init(history: OperationLog) {
        self.history = history
    }

    var filteredApps: [InstalledApp] {
        var result = apps
        if !search.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .size: result.sort { $0.bundleBytes > $1.bundleBytes }
        case .name: result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed:
            result.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
        return result
    }

    var unusedApps: [InstalledApp] {
        apps.filter { ($0.idleDays ?? 0) > 120 && !$0.isRunning }
            .sorted { $0.bundleBytes > $1.bundleBytes }
    }

    var orphanedStartupItems: [StartupItem] { startupItems.filter(\.isOrphaned) }

    var totalAppBytes: Int64 { apps.reduce(0) { $0 + $1.bundleBytes } }

    func load() {
        guard !isLoading else { return }
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration
        // NSWorkspace is main-actor only; capture before leaving the main thread.
        let running = RunningApps.snapshot()

        queue.async { [weak self] in
            // Publish the list as soon as it exists, then fill in sizes. The
            // user sees a complete, usable list in milliseconds instead of
            // waiting on several seconds of bundle measurement.
            let discovered = AppInventory.scan(running: running)
            let startup = StartupInventory.scan()
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                withAnimation(Motion.enter) {
                    self.apps = discovered
                    self.startupItems = startup
                }
            }

            let measured = AppInventory.measured(discovered)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                withAnimation(Motion.enter) {
                    self.apps = measured
                    self.isLoading = false
                }
            }
        }
    }

    func checkUpdates() {
        guard HomebrewBridge.isAvailable, !isCheckingUpdates else { return }
        isCheckingUpdates = true
        queue.async { [weak self] in
            let outdated = HomebrewBridge.outdatedCasks()
            DispatchQueue.main.async {
                guard let self else { return }
                withAnimation(Motion.enter) {
                    self.outdated = outdated
                    self.isCheckingUpdates = false
                }
            }
        }
    }

    // MARK: - Uninstall

    func preparePlan(for app: InstalledApp) {
        isBuildingPlan = true
        plan = nil
        uninstallOutcome = nil
        queue.async { [weak self] in
            let plan = LeftoverFinder.plan(for: app)
            DispatchQueue.main.async {
                guard let self else { return }
                self.plan = plan
                // Preselect the bundle and every leftover we can name concrete
                // bundle-identifier evidence for. Name-only matches start off.
                self.planSelection = Set(
                    plan.leftovers
                        .filter { $0.evidence.contains("bundle identifier") || $0.kind != .support }
                        .map(\.id)
                )
                self.planSelection.insert(plan.bundle.path)
                self.isBuildingPlan = false
            }
        }
    }

    func dismissPlan() {
        plan = nil
        planSelection = []
        uninstallOutcome = nil
    }

    var planSelectedBytes: Int64 {
        guard let plan else { return 0 }
        var total: Int64 = 0
        if planSelection.contains(plan.bundle.path) { total += plan.app.bundleBytes }
        total += plan.leftovers.filter { planSelection.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        return total
    }

    func performUninstall() {
        guard let plan, !isUninstalling else { return }
        isUninstalling = true

        var urls: [URL] = []
        var sizes: [URL: Int64] = [:]
        if planSelection.contains(plan.bundle.path) {
            urls.append(plan.bundle)
            sizes[plan.bundle] = plan.app.bundleBytes
        }
        for leftover in plan.leftovers where planSelection.contains(leftover.id) {
            urls.append(leftover.url)
            sizes[leftover.url] = leftover.bytes
        }

        let historyRef = history
        let name = plan.app.name

        queue.async { [weak self] in
            let remover = Remover(history: historyRef)
            let outcome = remover.remove(urls, disposal: .trash, knownSizes: sizes)
            _ = historyRef.commitSession(title: "Uninstalled \(name)")
            DispatchQueue.main.async {
                self?.uninstallOutcome = outcome
                self?.isUninstalling = false
                self?.load()
            }
        }
    }

    // MARK: - Startup

    func removeStartupItem(_ item: StartupItem) {
        guard item.scope == .userAgent else { return }
        let historyRef = history
        let url = item.url
        queue.async { [weak self] in
            StartupInventory.unload(item)
            let remover = Remover(history: historyRef)
            _ = remover.remove([url], disposal: .trash)
            _ = historyRef.commitSession(title: "Removed startup item")
            DispatchQueue.main.async { self?.load() }
        }
    }

    func upgrade(_ cask: HomebrewBridge.OutdatedCask) {
        queue.async { [weak self] in
            _ = HomebrewBridge.upgradeCask(cask.token)
            DispatchQueue.main.async { self?.checkUpdates() }
        }
    }
}
