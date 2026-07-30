import ApexCore
import SwiftUI

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
    /// Which row is waiting on its leftover scan, so only that button spins.
    @Published private(set) var pendingUninstallID: String?
    @Published var planSelection: Set<String> = []
    @Published private(set) var uninstallOutcome: Remover.Outcome?
    @Published private(set) var isUninstalling = false
    /// Cask tokens currently being upgraded. A cask upgrade downloads an entire
    /// application, so "nothing appears to happen for four minutes" is the
    /// default experience unless the button says otherwise.
    @Published private(set) var upgrading: Set<String> = []
    @Published private(set) var upgraded: Set<String> = []
    /// Why an upgrade failed, keyed by token. Homebrew fails for ordinary,
    /// fixable reasons — the app is open, or the cask needs an admin password —
    /// and silently doing nothing is the worst possible response.
    @Published private(set) var upgradeFailures: [String: String] = [:]
    /// Startup items mid-removal, so their row can show progress.
    @Published private(set) var removingStartupItems: Set<String> = []

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

    /// True when the last check did not finish, so an empty list means "we do
    /// not know" rather than "nothing is outdated".
    @Published private(set) var updateCheckFailed = false
    /// The Homebrew cask deregistered after an uninstall, if there was one.
    @Published private(set) var forgottenCask: String?

    func checkUpdates() {
        guard HomebrewBridge.isAvailable, !isCheckingUpdates else { return }
        isCheckingUpdates = true
        queue.async { [weak self] in
            let result = HomebrewBridge.outdatedCaskResult()
            DispatchQueue.main.async {
                guard let self else { return }
                withAnimation(Motion.enter) {
                    self.outdated = result.casks
                    self.updateCheckFailed = !result.isReliable
                    self.isCheckingUpdates = false
                }
            }
        }
    }

    // MARK: - Uninstall

    func preparePlan(for app: InstalledApp) {
        guard !isBuildingPlan else { return }
        isBuildingPlan = true
        pendingUninstallID = app.id
        plan = nil
        uninstallOutcome = nil
        queue.async { [weak self] in
            let plan = LeftoverFinder.plan(for: app)
            DispatchQueue.main.async {
                guard let self else { return }
                self.plan = plan
                // Preselect only matches strong enough to justify deleting
                // without being looked at: the app's own bundle, and paths named
                // for its bundle identifier or its full name.
                //
                // This used to preselect anything that was not Application
                // Support, which meant a directory matched on a shortened name —
                // Caches/Microsoft, Logs/Adobe — arrived already ticked.
                //
                // A bundle identifier is only unique if exactly one installed
                // app claims it. `iStat Menus.app` and `iStat Menus 6.app` both
                // declare `com.bjango.istatmenus`, so uninstalling either one
                // would have auto-ticked the preferences, containers and group
                // containers that the surviving copy is still using — signing
                // the user out and wiping its configuration.
                let sharedIdentifier =
                    self.apps.filter { $0.bundleID == app.bundleID }.count > 1
                self.planSelection = Set(
                    plan.leftovers
                        .filter { leftover in
                            guard leftover.confidence.isSafeToPreselect else { return false }
                            if sharedIdentifier, leftover.confidence == .bundleIdentifier {
                                return false
                            }
                            return true
                        }
                        .map(\.id)
                )
                self.planSelection.insert(plan.bundle.path)
                self.isBuildingPlan = false
                self.pendingUninstallID = nil
            }
        }
    }

    func dismissPlan() {
        plan = nil
        planSelection = []
        uninstallOutcome = nil
        forgottenCask = nil
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
        let bundlePath = plan.bundle.standardizedFileURL.path
        let removingBundle = planSelection.contains(plan.bundle.path)

        queue.async { [weak self] in
            let remover = Remover(history: historyRef)
            let outcome = remover.remove(urls, disposal: .trash, knownSizes: sizes)

            // Homebrew has to be told, or it still believes the cask is
            // installed: `brew list --cask` keeps reporting it, its staged
            // payload stays on disk, and `brew outdated` keeps offering it — so
            // the app reappears in ApexClean's own Updates tab and pressing
            // Update reinstalls what the user just removed.
            var forgotten: String?
            if removingBundle,
                outcome.removed.contains(where: {
                    $0.standardizedFileURL.path == bundlePath
                })
            {
                let token = HomebrewBridge.caskTokensByAppPath()[bundlePath]
                if let token, HomebrewBridge.forgetCask(token) { forgotten = token }
            }

            _ = historyRef.commitSession(title: "Uninstalled \(name)")
            DispatchQueue.main.async {
                self?.uninstallOutcome = outcome
                self?.forgottenCask = forgotten
                self?.isUninstalling = false
                self?.load()
            }
        }
    }

    // MARK: - Startup

    func removeStartupItem(_ item: StartupItem) {
        guard item.scope == .userAgent, !removingStartupItems.contains(item.id) else { return }
        removingStartupItems.insert(item.id)
        let historyRef = history
        let url = item.url
        let id = item.id
        queue.async { [weak self] in
            StartupInventory.unload(item)
            let remover = Remover(history: historyRef)
            _ = remover.remove([url], disposal: .trash)
            _ = historyRef.commitSession(title: "Removed startup item")
            DispatchQueue.main.async {
                self?.removingStartupItems.remove(id)
                self?.load()
            }
        }
    }

    func upgrade(_ cask: HomebrewBridge.OutdatedCask) {
        guard !upgrading.contains(cask.token) else { return }
        upgrading.insert(cask.token)
        upgradeFailures[cask.token] = nil
        let token = cask.token

        // Its own queue, not the shared serial one: a cask upgrade downloads a
        // whole application and can run for minutes, and nothing else in this
        // screen should be stuck behind it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = HomebrewBridge.upgrade(token)
            DispatchQueue.main.async {
                guard let self else { return }
                self.upgrading.remove(token)
                if outcome.succeeded {
                    self.upgraded.insert(token)
                    self.outdated.removeAll { $0.token == token }
                    // Re-read the inventory so the installed version and size
                    // reflect the app that is now actually on disk.
                    self.load()
                } else {
                    self.upgradeFailures[token] = outcome.message
                }
            }
        }
    }

    func upgradeAll() {
        for cask in outdated where !upgrading.contains(cask.token) {
            upgrade(cask)
        }
    }
}
