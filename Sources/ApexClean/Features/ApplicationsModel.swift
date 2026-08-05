@preconcurrency import ApexCore
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
    @Published private(set) var startupRemovalFailures: [String: String] = [:]

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
    private let upgradeQueue = DispatchQueue(
        label: "fit.apexclean.apps.upgrades",
        qos: .userInitiated
    )
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
        let model = self

        queue.async {
            // Publish the list as soon as it exists, then fill in sizes. The
            // user sees a complete, usable list in milliseconds instead of
            // waiting on several seconds of bundle measurement.
            let discovered = AppInventory.scan(running: running)
            let startup = StartupInventory.scan()
            DispatchQueue.main.async {
                guard model.loadGeneration == generation else { return }
                withAnimation(Motion.enter) {
                    model.apps = discovered
                    model.startupItems = startup
                }
            }

            let measured = AppInventory.measured(discovered)
            DispatchQueue.main.async {
                guard model.loadGeneration == generation else { return }
                withAnimation(Motion.enter) {
                    model.apps = measured
                    model.isLoading = false
                }
            }
        }
    }

    /// True when the last check did not finish, so an empty list means "we do
    /// not know" rather than "nothing is outdated".
    @Published private(set) var updateCheckFailed = false
    /// The Homebrew cask deregistered after an uninstall, if there was one.

    func checkUpdates() {
        guard HomebrewBridge.isAvailable, !isCheckingUpdates else { return }
        isCheckingUpdates = true
        let model = self
        queue.async {
            let result = HomebrewBridge.outdatedCaskResult()
            DispatchQueue.main.async {
                withAnimation(Motion.enter) {
                    model.outdated = result.casks
                    model.updateCheckFailed = !result.isReliable
                    model.isCheckingUpdates = false
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
        let model = self
        let running = RunningApps.snapshot()
        queue.async {
            let plan = LeftoverFinder.plan(for: app)
            let identifier = app.bundleID.lowercased()
            let liveSiblings =
                AppInventory.scan(running: running)
                .filter { $0.bundleID.lowercased() == identifier }
                .count
            DispatchQueue.main.async {
                model.plan = plan
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
                let sharedIdentifier = identifier.isEmpty || liveSiblings != 1
                model.planSelection = Set(
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
                model.planSelection.insert(plan.bundle.path)
                model.isBuildingPlan = false
                model.pendingUninstallID = nil
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
        guard plan.uninstallVerdict.isAllowed else {
            var outcome = Remover.Outcome()
            outcome.refused.append(
                (plan.bundle, plan.uninstallVerdict.reason ?? "ApexClean refused this uninstall")
            )
            uninstallOutcome = outcome
            return
        }

        let running = RunningApps.snapshot()
        guard !running.contains(plan.app.bundleID) else {
            var outcome = Remover.Outcome()
            outcome.refused.append((plan.bundle, "\(plan.app.name) is currently running"))
            uninstallOutcome = outcome
            return
        }

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
        let removalURLs = urls
        let removalSizes = sizes
        let launchAgentURLs = Set(
            plan.leftovers
                .filter { $0.kind == .launchAgents && planSelection.contains($0.id) }
                .map(\.url)
        )
        let model = self
        let identifier = plan.app.bundleID.lowercased()
        let selectedIdentifierLeftovers = plan.leftovers.contains {
            planSelection.contains($0.id) && $0.confidence == .bundleIdentifier
        }

        queue.async {
            let liveSiblings =
                AppInventory.scan(running: running)
                .filter { $0.bundleID.lowercased() == identifier }
                .count
            guard !selectedIdentifierLeftovers || (!identifier.isEmpty && liveSiblings == 1) else {
                var refused = Remover.Outcome()
                refused.refused.append(
                    (
                        plan.bundle,
                        "Another installed application shares this bundle identifier"
                    )
                )
                let refusedOutcome = refused
                DispatchQueue.main.async {
                    model.uninstallOutcome = refusedOutcome
                    model.isUninstalling = false
                }
                return
            }
            guard Bundle(url: plan.bundle)?.bundleIdentifier?.lowercased() == identifier else {
                var refused = Remover.Outcome()
                refused.refused.append((plan.bundle, "The application changed after review"))
                let refusedOutcome = refused
                DispatchQueue.main.async {
                    model.uninstallOutcome = refusedOutcome
                    model.isUninstalling = false
                }
                return
            }
            let remover = Remover()
            var safeURLs = removalURLs
            var preloadRefusals: [(url: URL, reason: String)] = []
            for url in launchAgentURLs where !StartupInventory.unload(plist: url) {
                safeURLs.removeAll { $0 == url }
                preloadRefusals.append(
                    (url, "The launch job could not be unloaded, so its plist was left in place")
                )
            }
            var outcome = remover.remove(
                safeURLs,
                disposal: .trash,
                knownSizes: removalSizes
            )
            outcome.refused += preloadRefusals

            _ = historyRef.commitSession(
                title: "Uninstalled \(name)",
                entries: outcome.historyEntries
            )
            let finalOutcome = outcome
            DispatchQueue.main.async {
                model.uninstallOutcome = finalOutcome
                model.isUninstalling = false
                model.load()
            }
        }
    }

    // MARK: - Startup

    func removeStartupItem(_ item: StartupItem) {
        guard item.scope == .userAgent,
            !item.isApple,
            !removingStartupItems.contains(item.id)
        else { return }
        removingStartupItems.insert(item.id)
        startupRemovalFailures[item.id] = nil
        let historyRef = history
        let url = item.url
        let id = item.id
        let model = self
        queue.async {
            guard StartupInventory.unload(item) else {
                DispatchQueue.main.async {
                    model.removingStartupItems.remove(id)
                    model.startupRemovalFailures[id] =
                        "The launch job could not be unloaded, so its plist was left in place."
                }
                return
            }
            let remover = Remover()
            let outcome = remover.remove([url], disposal: .trash)
            _ = historyRef.commitSession(
                title: "Removed startup item",
                entries: outcome.historyEntries
            )
            DispatchQueue.main.async {
                model.removingStartupItems.remove(id)
                model.startupRemovalFailures[id] =
                    outcome.refused.first?.reason ?? outcome.failed.first?.error
                model.load()
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
        let model = self
        upgradeQueue.async {
            let outcome = HomebrewBridge.upgrade(token)
            DispatchQueue.main.async {
                model.upgrading.remove(token)
                if outcome.succeeded {
                    model.upgraded.insert(token)
                    model.outdated.removeAll { $0.token == token }
                    // Re-read the inventory so the installed version and size
                    // reflect the app that is now actually on disk.
                    model.load()
                } else {
                    model.upgradeFailures[token] = outcome.message
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
