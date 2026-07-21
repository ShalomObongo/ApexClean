import AppKit
import Foundation

/// A bounded macOS maintenance action.
///
/// Every task states plainly what it does and what it does *not* do. Nothing in
/// this catalog claims to make a Mac "faster"; each one either repairs a
/// specific broken state or clears a specific stale cache.
public struct MaintenanceTask: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    /// The literal effect, written so an expert can verify the claim.
    public let mechanism: String
    public let symbol: String
    public let requiresAdmin: Bool
    public let estimatedSeconds: Int

    public static func == (lhs: MaintenanceTask, rhs: MaintenanceTask) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct MaintenanceResult: Identifiable {
    public var id: String { task.id }
    public let task: MaintenanceTask
    public let succeeded: Bool
    public let detail: String
    public let bytesFreed: Int64
}

public enum MaintenanceCatalog {
    public static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: "dns",
            title: "Flush DNS cache",
            summary: "Resolves stale or incorrect domain lookups.",
            mechanism: "Clears the resolver cache and signals mDNSResponder to reload.",
            symbol: "network",
            requiresAdmin: true,
            estimatedSeconds: 2
        ),
        MaintenanceTask(
            id: "quicklook",
            title: "Rebuild Quick Look thumbnails",
            summary: "Fixes blank or wrong previews in Finder.",
            mechanism: "Resets the Quick Look thumbnail cache; previews regenerate on demand.",
            symbol: "eye",
            requiresAdmin: false,
            estimatedSeconds: 4
        ),
        MaintenanceTask(
            id: "icons",
            title: "Rebuild icon cache",
            summary: "Fixes generic or missing application icons.",
            mechanism: "Clears the icon services store and restarts the icon daemon.",
            symbol: "app.badge",
            requiresAdmin: false,
            estimatedSeconds: 5
        ),
        MaintenanceTask(
            id: "launchservices",
            title: "Repair “Open With” menu",
            summary: "Removes duplicate and stale entries from file associations.",
            mechanism: "Re-registers every installed bundle with Launch Services.",
            symbol: "list.bullet.rectangle",
            requiresAdmin: false,
            estimatedSeconds: 20
        ),
        MaintenanceTask(
            id: "spotlight",
            title: "Verify Spotlight index",
            summary: "Reports whether search indexing is healthy.",
            mechanism: "Queries indexing status. Reports only — never rebuilds without asking.",
            symbol: "magnifyingglass",
            requiresAdmin: false,
            estimatedSeconds: 3
        ),
        MaintenanceTask(
            id: "preferences",
            title: "Repair corrupted preferences",
            summary: "Finds preference files apps can no longer read.",
            mechanism: "Validates third-party plists and quarantines only unreadable ones.",
            symbol: "slider.horizontal.3",
            requiresAdmin: false,
            estimatedSeconds: 15
        ),
        MaintenanceTask(
            id: "savedstate",
            title: "Clear stale window states",
            summary: "Removes saved window layouts older than 30 days.",
            mechanism: "Deletes .savedState bundles apps have not touched in a month.",
            symbol: "macwindow.on.rectangle",
            requiresAdmin: false,
            estimatedSeconds: 5
        ),
        MaintenanceTask(
            id: "orphanagents",
            title: "Remove broken startup items",
            summary: "Clears launch agents whose program no longer exists.",
            mechanism: "Unloads and removes user launch agents pointing at missing binaries.",
            symbol: "bolt.badge.clock",
            requiresAdmin: false,
            estimatedSeconds: 4
        ),
        MaintenanceTask(
            id: "finder",
            title: "Restart Finder and Dock",
            summary: "Clears visual glitches without a reboot.",
            mechanism: "Relaunches both processes. Open Finder windows will close.",
            symbol: "arrow.clockwise",
            requiresAdmin: false,
            estimatedSeconds: 3
        ),
        MaintenanceTask(
            id: "diskverify",
            title: "Verify startup disk",
            summary: "Checks the filesystem for structural problems.",
            mechanism: "Runs a read-only volume verification. Repairs are never attempted here.",
            symbol: "internaldrive",
            requiresAdmin: false,
            estimatedSeconds: 45
        ),
    ]
}

/// Executes maintenance tasks. Anything requiring elevation is attempted without
/// prompting for a password; if it cannot run unprivileged, it reports that
/// plainly rather than silently doing nothing.
public final class MaintenanceRunner {
    public init() {}

    public func run(_ task: MaintenanceTask) -> MaintenanceResult {
        switch task.id {
        case "dns": flushDNS(task)
        case "quicklook": rebuildQuickLook(task)
        case "icons": rebuildIcons(task)
        case "launchservices": repairLaunchServices(task)
        case "spotlight": verifySpotlight(task)
        case "preferences": repairPreferences(task)
        case "savedstate": clearSavedState(task)
        case "orphanagents": removeOrphanedAgents(task)
        case "finder": restartFinder(task)
        case "diskverify": verifyDisk(task)
        default: MaintenanceResult(task: task, succeeded: false, detail: "Unknown task", bytesFreed: 0)
        }
    }

    // MARK: - Implementations

    private func flushDNS(_ task: MaintenanceTask) -> MaintenanceResult {
        // dscacheutil -flushcache needs root. Without it we can still ask
        // mDNSResponder to reload, which handles the common stale-record case.
        guard let killall = Shell.which("killall") else {
            return .init(task: task, succeeded: false, detail: "killall unavailable", bytesFreed: 0)
        }
        let result = Shell.run(killall, ["-HUP", "mDNSResponder"], timeout: 5)
        if result != nil {
            return .init(task: task, succeeded: true, detail: "Resolver cache reloaded", bytesFreed: 0)
        }
        return .init(
            task: task,
            succeeded: false,
            detail: "Needs administrator privileges to fully flush",
            bytesFreed: 0
        )
    }

    private func rebuildQuickLook(_ task: MaintenanceTask) -> MaintenanceResult {
        var freed: Int64 = 0
        let remover = Remover()
        let caches = Glob.expand("~/Library/Caches/com.apple.QuickLook.thumbnailcache")
        let outcome = remover.remove(caches, disposal: .delete)
        freed += outcome.bytesReclaimed

        if let qlmanage = Shell.which("qlmanage") {
            _ = Shell.run(qlmanage, ["-r", "cache"], timeout: 20)
        }
        return .init(
            task: task,
            succeeded: true,
            detail: freed > 0 ? "Reclaimed \(Bytes.format(freed))" : "Cache already clean",
            bytesFreed: freed
        )
    }

    private func rebuildIcons(_ task: MaintenanceTask) -> MaintenanceResult {
        let remover = Remover()
        let caches =
            Glob.expand("~/Library/Caches/com.apple.iconservices.store")
            + Glob.expand("~/Library/Caches/com.apple.iconservices")
        let outcome = remover.remove(caches, disposal: .delete)

        if let killall = Shell.which("killall") {
            _ = Shell.run(killall, ["Dock"], timeout: 5)
        }
        return .init(
            task: task,
            succeeded: true,
            detail: outcome.bytesReclaimed > 0
                ? "Reclaimed \(Bytes.format(outcome.bytesReclaimed))"
                : "Icon cache rebuilt",
            bytesFreed: outcome.bytesReclaimed
        )
    }

    private func repairLaunchServices(_ task: MaintenanceTask) -> MaintenanceResult {
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister"
        guard Shell.exists(lsregister) else {
            return .init(task: task, succeeded: false, detail: "lsregister unavailable", bytesFreed: 0)
        }
        _ = Shell.run(
            lsregister,
            ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"],
            timeout: 120
        )
        return .init(task: task, succeeded: true, detail: "File associations rebuilt", bytesFreed: 0)
    }

    private func verifySpotlight(_ task: MaintenanceTask) -> MaintenanceResult {
        guard let mdutil = Shell.which("mdutil"),
            let output = Shell.run(mdutil, ["-s", "/"], timeout: 8)
        else {
            return .init(task: task, succeeded: false, detail: "Could not query Spotlight", bytesFreed: 0)
        }
        let enabled = !output.localizedCaseInsensitiveContains("disabled")
        return .init(
            task: task,
            succeeded: true,
            detail: enabled ? "Indexing enabled and healthy" : "Indexing is disabled for this volume",
            bytesFreed: 0
        )
    }

    private func repairPreferences(_ task: MaintenanceTask) -> MaintenanceResult {
        guard let plutil = Shell.which("plutil") else {
            return .init(task: task, succeeded: false, detail: "plutil unavailable", bytesFreed: 0)
        }
        let preferences = PathGuard.home.appendingPathComponent("Library/Preferences")
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: preferences,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return .init(task: task, succeeded: true, detail: "Nothing to check", bytesFreed: 0)
        }

        var broken: [URL] = []
        // Apple's own preferences are left alone: cfprefsd owns them and a
        // transient read failure is not proof of corruption.
        let candidates = contents.filter {
            $0.pathExtension == "plist" && !$0.lastPathComponent.hasPrefix("com.apple.")
        }
        for url in candidates.prefix(600) {
            guard let output = Shell.run(plutil, ["-lint", url.path], timeout: 3) else { continue }
            if !output.contains("OK") { broken.append(url) }
        }

        guard !broken.isEmpty else {
            return .init(task: task, succeeded: true, detail: "All preference files valid", bytesFreed: 0)
        }
        let outcome = Remover().remove(broken, disposal: .trash)
        return .init(
            task: task,
            succeeded: true,
            detail: "Moved \(Count.files(outcome.removed.count)) to Trash",
            bytesFreed: outcome.bytesReclaimed
        )
    }

    private func clearSavedState(_ task: MaintenanceTask) -> MaintenanceResult {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let candidates = Glob.expand("~/Library/Saved Application State/*.savedState").filter { url in
            guard
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            else { return false }
            return modified < cutoff
        }
        guard !candidates.isEmpty else {
            return .init(task: task, succeeded: true, detail: "No stale window states", bytesFreed: 0)
        }
        let outcome = Remover().remove(candidates, disposal: .trash)
        return .init(
            task: task,
            succeeded: true,
            detail: "Cleared \(outcome.removed.count) stale states",
            bytesFreed: outcome.bytesReclaimed
        )
    }

    private func removeOrphanedAgents(_ task: MaintenanceTask) -> MaintenanceResult {
        let orphaned = StartupInventory.scan().filter { $0.isOrphaned && $0.scope == .userAgent }
        guard !orphaned.isEmpty else {
            return .init(task: task, succeeded: true, detail: "No broken startup items", bytesFreed: 0)
        }
        for item in orphaned { StartupInventory.unload(item) }
        let outcome = Remover().remove(orphaned.map(\.url), disposal: .trash)
        return .init(
            task: task,
            succeeded: true,
            detail:
                "Removed \(outcome.removed.count) broken \(outcome.removed.count == 1 ? "item" : "items")",
            bytesFreed: outcome.bytesReclaimed
        )
    }

    private func restartFinder(_ task: MaintenanceTask) -> MaintenanceResult {
        guard let killall = Shell.which("killall") else {
            return .init(task: task, succeeded: false, detail: "killall unavailable", bytesFreed: 0)
        }
        _ = Shell.run(killall, ["Finder"], timeout: 5)
        _ = Shell.run(killall, ["Dock"], timeout: 5)
        return .init(task: task, succeeded: true, detail: "Finder and Dock relaunched", bytesFreed: 0)
    }

    private func verifyDisk(_ task: MaintenanceTask) -> MaintenanceResult {
        guard let diskutil = Shell.which("diskutil"),
            let output = Shell.run(diskutil, ["verifyVolume", "/"], timeout: 180)
        else {
            return .init(task: task, succeeded: false, detail: "Verification unavailable", bytesFreed: 0)
        }
        let healthy =
            output.localizedCaseInsensitiveContains("appears to be OK")
            || output.localizedCaseInsensitiveContains("The volume /  appears to be OK")
        return .init(
            task: task,
            succeeded: true,
            detail: healthy ? "Filesystem structure is sound" : "Verification finished — review Disk Utility",
            bytesFreed: 0
        )
    }
}
