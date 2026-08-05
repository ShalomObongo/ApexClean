import AppKit
import Foundation

/// A bounded macOS maintenance action.
///
/// Every task states plainly what it does and what it does *not* do. Nothing in
/// this catalog claims to make a Mac "faster"; each one either repairs a
/// specific broken state or clears a specific stale cache.
public struct MaintenanceTask: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// The literal effect, written so an expert can verify the claim.
    public let mechanism: String
    public let symbol: String
    public let requiresAdmin: Bool
    public let estimatedSeconds: Int

    public var isDestructive: Bool {
        ["quicklook", "icons", "preferences", "savedstate", "orphanagents"].contains(id)
    }

    public static func == (lhs: MaintenanceTask, rhs: MaintenanceTask) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct MaintenanceResult: Identifiable, Sendable {
    public var id: String { task.id }
    public let task: MaintenanceTask
    public let succeeded: Bool
    public let detail: String
    public let bytesFreed: Int64
    public var historyEntries: [OperationLog.Entry] = []

    public init(
        task: MaintenanceTask,
        succeeded: Bool,
        detail: String,
        bytesFreed: Int64,
        historyEntries: [OperationLog.Entry] = []
    ) {
        self.task = task
        self.succeeded = succeeded
        self.detail = detail
        self.bytesFreed = bytesFreed
        self.historyEntries = historyEntries
    }
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
            mechanism:
                "Validates readable third-party plists twice, then permanently deletes only files confirmed invalid.",
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
public final class MaintenanceRunner: Sendable {
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
        // Both halves need root: mDNSResponder runs as `_mdnsresponder`, so a
        // user-level SIGHUP is rejected outright. The previous version called
        // `Shell.run`, which discards stderr *and* the exit status, so a refused
        // signal came back as an empty string — non-nil — and was reported as
        // "Resolver cache reloaded". It claimed to have done something it had
        // never once succeeded at.
        guard let killall = Shell.which("killall") else {
            return .init(task: task, succeeded: false, detail: "killall unavailable", bytesFreed: 0)
        }

        let signal = Shell.runDetailed(killall, ["-HUP", "mDNSResponder"], timeout: 5)
        guard signal.status == 0 else {
            return .init(
                task: task,
                succeeded: false,
                detail: "Needs administrator privileges — run "
                    + "`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`",
                bytesFreed: 0
            )
        }

        // The resolver reloaded, but the directory-service cache in front of it
        // is a separate store and only root can clear it.
        var detail = "Resolver cache reloaded"
        if let dscacheutil = Shell.which("dscacheutil"),
            Shell.runDetailed(dscacheutil, ["-flushcache"], timeout: 5).status == 0
        {
            detail = "Resolver reloaded and directory cache flushed"
        }
        return .init(task: task, succeeded: true, detail: detail, bytesFreed: 0)
    }

    private func rebuildQuickLook(_ task: MaintenanceTask) -> MaintenanceResult {
        var freed: Int64 = 0
        let remover = Remover()
        let caches = Glob.expand("~/Library/Caches/com.apple.QuickLook.thumbnailcache")
        let outcome = remover.remove(caches, disposal: .delete)
        freed += outcome.bytesFreed

        var commandSucceeded = true
        if let qlmanage = Shell.which("qlmanage") {
            commandSucceeded =
                Shell.runDetailed(
                    qlmanage,
                    ["-r", "cache"],
                    timeout: 20
                ).succeeded
        }
        let succeeded = outcome.failed.isEmpty && outcome.refused.isEmpty && commandSucceeded
        return .init(
            task: task,
            succeeded: succeeded,
            detail: succeeded
                ? (freed > 0 ? "Reclaimed \(Bytes.format(freed))" : "Cache already clean")
                : "Quick Look cache could not be rebuilt completely",
            bytesFreed: freed,
            historyEntries: outcome.historyEntries
        )
    }

    private func rebuildIcons(_ task: MaintenanceTask) -> MaintenanceResult {
        let remover = Remover()
        let caches =
            Glob.expand("~/Library/Caches/com.apple.iconservices.store")
            + Glob.expand("~/Library/Caches/com.apple.iconservices")
        let outcome = remover.remove(caches, disposal: .delete)

        let restarted =
            Shell.which("killall").map {
                Shell.runDetailed($0, ["Dock"], timeout: 5).succeeded
            } ?? false
        let succeeded = outcome.failed.isEmpty && outcome.refused.isEmpty && restarted
        return .init(
            task: task,
            succeeded: succeeded,
            detail: succeeded
                ? (outcome.bytesFreed > 0
                    ? "Freed \(Bytes.format(outcome.bytesFreed))"
                    : "Icon cache rebuilt")
                : "Icon cache could not be rebuilt completely",
            bytesFreed: outcome.bytesFreed,
            historyEntries: outcome.historyEntries
        )
    }

    private func repairLaunchServices(_ task: MaintenanceTask) -> MaintenanceResult {
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister"
        guard Shell.exists(lsregister) else {
            return .init(task: task, succeeded: false, detail: "lsregister unavailable", bytesFreed: 0)
        }
        let result = Shell.runDetailed(
            lsregister,
            ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"],
            timeout: 120
        )
        return .init(
            task: task,
            succeeded: result.succeeded,
            detail: result.succeeded
                ? "File associations rebuilt"
                : (result.lastMeaningfulLine ?? "Launch Services rebuild failed"),
            bytesFreed: 0
        )
    }

    private func verifySpotlight(_ task: MaintenanceTask) -> MaintenanceResult {
        guard let mdutil = Shell.which("mdutil")
        else {
            return .init(task: task, succeeded: false, detail: "Could not query Spotlight", bytesFreed: 0)
        }
        let result = Shell.runDetailed(mdutil, ["-s", "/"], timeout: 8)
        guard result.succeeded else {
            return .init(
                task: task,
                succeeded: false,
                detail: result.lastMeaningfulLine ?? "Could not query Spotlight",
                bytesFreed: 0
            )
        }
        let output = result.output
        let enabled = !output.localizedCaseInsensitiveContains("disabled")
        return .init(
            task: task,
            succeeded: enabled,
            detail: enabled ? "Indexing enabled and healthy" : "Indexing is disabled for this volume",
            bytesFreed: 0
        )
    }

    private func repairPreferences(_ task: MaintenanceTask) -> MaintenanceResult {
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
        func isConfirmedInvalid(_ url: URL) -> Bool? {
            guard
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                ),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let size = values.fileSize,
                size <= 16 * 1024 * 1024,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
            else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
        }
        let limit = 600
        var unreadable = 0
        for url in candidates.prefix(limit) {
            guard let invalid = isConfirmedInvalid(url) else {
                unreadable += 1
                continue
            }
            if invalid { broken.append(url) }
        }

        var notes: [String] = []
        if candidates.count > limit {
            notes.append("checked the first \(limit) of \(candidates.count)")
        }
        if unreadable > 0 { notes.append("\(Count.files(unreadable)) could not be checked") }
        let suffix = notes.isEmpty ? "" : " · " + notes.joined(separator: ", ")

        guard !broken.isEmpty else {
            return .init(
                task: task,
                succeeded: true,
                detail: "All preference files valid" + suffix,
                bytesFreed: 0
            )
        }
        let outcome = Remover(
            refusalBeforeDispose: { url in
                isConfirmedInvalid(url) == true
                    ? nil
                    : "The preference file is no longer confirmed corrupt"
            }
        ).remove(broken, disposal: .delete)
        let succeeded = outcome.failed.isEmpty && outcome.refused.isEmpty
        return .init(
            task: task,
            succeeded: succeeded,
            detail: succeeded
                ? "Deleted \(Count.files(outcome.removed.count)) invalid preferences" + suffix
                : "Some invalid preferences could not be deleted" + suffix,
            bytesFreed: outcome.bytesFreed,
            historyEntries: outcome.historyEntries
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
        let outcome = Remover().remove(candidates, disposal: .delete)
        let succeeded = outcome.failed.isEmpty && outcome.refused.isEmpty
        return .init(
            task: task,
            succeeded: succeeded,
            detail: succeeded
                ? "Cleared \(outcome.removed.count) stale states"
                : "Some stale states could not be deleted",
            bytesFreed: outcome.bytesFreed,
            historyEntries: outcome.historyEntries
        )
    }

    private func removeOrphanedAgents(_ task: MaintenanceTask) -> MaintenanceResult {
        let orphaned = StartupInventory.scan().filter { $0.isOrphaned && $0.scope == .userAgent }
        guard !orphaned.isEmpty else {
            return .init(task: task, succeeded: true, detail: "No broken startup items", bytesFreed: 0)
        }
        var removable: [StartupItem] = []
        var transitioned: [URL] = []
        for item in orphaned {
            switch StartupInventory.unloadOutcome(item) {
            case .unloaded:
                removable.append(item)
                transitioned.append(item.url)
            case .alreadyUnloaded:
                removable.append(item)
            case .failed:
                break
            }
        }
        var outcome = Remover().remove(removable.map(\.url), disposal: .delete)
        let removed = Set(outcome.removed.map { $0.standardizedFileURL.path })
        for url in transitioned
        where !removed.contains(url.standardizedFileURL.path)
            && !StartupInventory.reload(plist: url)
        {
            outcome.failed.append((url, "The launch job could not be restored"))
        }
        let succeeded =
            removable.count == orphaned.count
            && outcome.failed.isEmpty
            && outcome.refused.isEmpty
        return .init(
            task: task,
            succeeded: succeeded,
            detail: succeeded
                ? "Removed \(outcome.removed.count) broken \(outcome.removed.count == 1 ? "item" : "items")"
                : "Some startup jobs could not be unloaded or removed",
            bytesFreed: outcome.bytesFreed,
            historyEntries: outcome.historyEntries
        )
    }

    private func restartFinder(_ task: MaintenanceTask) -> MaintenanceResult {
        guard let killall = Shell.which("killall") else {
            return .init(task: task, succeeded: false, detail: "killall unavailable", bytesFreed: 0)
        }
        let finder = Shell.runDetailed(killall, ["Finder"], timeout: 5)
        let dock = Shell.runDetailed(killall, ["Dock"], timeout: 5)
        let succeeded = finder.succeeded && dock.succeeded
        return .init(
            task: task,
            succeeded: succeeded,
            detail: succeeded ? "Finder and Dock relaunched" : "Finder or Dock could not be relaunched",
            bytesFreed: 0
        )
    }

    private func verifyDisk(_ task: MaintenanceTask) -> MaintenanceResult {
        guard let diskutil = Shell.which("diskutil") else {
            return .init(task: task, succeeded: false, detail: "Verification unavailable", bytesFreed: 0)
        }

        let result = Shell.runDetailed(diskutil, ["verifyVolume", "/"], timeout: 180)
        if result.timedOut {
            return .init(
                task: task,
                succeeded: false,
                detail: "Verification did not finish in time — run it from Disk Utility",
                bytesFreed: 0
            )
        }

        let output = result.output
        let healthy =
            result.status == 0 && output.localizedCaseInsensitiveContains("appears to be OK")

        // A verification that found damage is a failed task, not a successful
        // one with an ambiguous note. Reporting it as success meant the single
        // most serious thing this app can discover was styled identically to a
        // cache being emptied.
        guard healthy else {
            let damaged = ["error", "corrupt", "invalid", "problems were found"]
                .contains { output.localizedCaseInsensitiveContains($0) }
            return .init(
                task: task,
                succeeded: false,
                detail: damaged
                    ? "Filesystem problems found — repair with `sudo diskutil repairVolume /`"
                    : "Verification was inconclusive — review Disk Utility",
                bytesFreed: 0
            )
        }

        return .init(
            task: task, succeeded: true, detail: "Filesystem structure is sound", bytesFreed: 0)
    }
}
