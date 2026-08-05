import Darwin
import Foundation

/// Performs removals and re-validates through `PathGuard` at the final boundary
/// rather than trusting a decision made earlier during the scan.
public final class Remover {
    public struct Outcome: @unchecked Sendable {
        public var removed: [URL] = []
        public var refused: [(url: URL, reason: String)] = []
        public var failed: [(url: URL, error: String)] = []
        /// Bytes moved or deleted by this operation.
        public var bytesProcessed: Int64 = 0
        /// Bytes actually released from the filesystem. Moving to Trash does
        /// not contribute until the Trash is emptied.
        public var bytesFreed: Int64 = 0
        @available(*, deprecated, renamed: "bytesProcessed")
        public var bytesReclaimed: Int64 {
            get { bytesProcessed }
            set { bytesProcessed = newValue }
        }
        public var filesRemoved: Int = 0
        public var trashed: Int = 0
        /// Where trashed items ended up.
        ///
        /// Kept so a Trash sweep in the same run can delete this pass's own
        /// items without charging for them a second time: moving a file to the
        /// Trash and then emptying it frees the space once, not twice.
        public var trashedLocations: [URL] = []
        public var historyEntries: [OperationLog.Entry] = []
        public var usedFinder = false

        public var isEmpty: Bool { removed.isEmpty && refused.isEmpty && failed.isEmpty }

        public init() {}

        public mutating func merge(_ other: Outcome) {
            removed += other.removed
            refused += other.refused
            failed += other.failed
            bytesProcessed += other.bytesProcessed
            bytesFreed += other.bytesFreed
            filesRemoved += other.filesRemoved
            trashed += other.trashed
            trashedLocations += other.trashedLocations
            historyEntries += other.historyEntries
            usedFinder = usedFinder || other.usedFinder
        }
    }

    public enum Disposal {
        /// Move to Trash. Retained for source compatibility with ApexCore 1.5.
        case trash
        /// Unlink directly after all safety and identity checks pass.
        case delete
    }

    private let beforeDispose: ((URL) -> Void)?
    private let refusalBeforeDispose: ((URL) -> String?)?
    private let legacyHistory: OperationLog?

    public convenience init(history: OperationLog? = nil) {
        self.init(history: history, beforeDispose: nil, refusalBeforeDispose: nil)
    }

    public convenience init(refusalBeforeDispose: @escaping (URL) -> String?) {
        self.init(
            history: nil,
            beforeDispose: nil,
            refusalBeforeDispose: refusalBeforeDispose
        )
    }

    init(beforeDispose: ((URL) -> Void)?) {
        self.legacyHistory = nil
        self.beforeDispose = beforeDispose
        self.refusalBeforeDispose = nil
    }

    private init(
        history: OperationLog?,
        beforeDispose: ((URL) -> Void)?,
        refusalBeforeDispose: ((URL) -> String?)?
    ) {
        self.legacyHistory = history
        self.beforeDispose = beforeDispose
        self.refusalBeforeDispose = refusalBeforeDispose
    }

    @discardableResult
    public func remove(
        _ urls: [URL],
        disposal: Disposal = .trash,
        allowUserRoots: Bool = false,
        knownSizes: [URL: Int64] = [:],
        stopAfterRefusal: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) -> Outcome {
        var outcome = Outcome()
        let total = urls.count

        for (index, url) in urls.enumerated() {
            defer { progress?(index + 1, total) }

            let verdict = PathGuard.evaluate(url, allowUserRoots: allowUserRoots)
            guard verdict.isAllowed else {
                let reason = verdict.reason ?? "Refused"
                Log.safety.notice("Refused \(url.path, privacy: .public): \(reason, privacy: .public)")
                outcome.refused.append((url, reason))
                continue
            }

            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let reason = Self.partialDownloadRefusal(for: url) {
                outcome.refused.append((url, reason))
                continue
            }
            if let reason = Self.developerToolsRefusal(for: url) {
                outcome.refused.append((url, reason))
                continue
            }
            guard let approvedIdentity = FileIdentity(url) else {
                outcome.refused.append((url, "Could not verify the filesystem identity"))
                if stopAfterRefusal { break }
                continue
            }

            if let reason = refusalBeforeDispose?(url) {
                outcome.refused.append((url, reason))
                if stopAfterRefusal { break }
                continue
            }
            let measurement: FileSize.Measurement
            if let known = knownSizes[url] {
                measurement = FileSize.Measurement(bytes: known, fileCount: 1)
            } else {
                measurement = FileSize.measure(url)
            }
            beforeDispose?(url)
            if let reason = refusalBeforeDispose?(url) {
                outcome.refused.append((url, reason))
                if stopAfterRefusal { break }
                continue
            }
            let finalVerdict = PathGuard.evaluate(url, allowUserRoots: allowUserRoots)
            guard finalVerdict.isAllowed else {
                outcome.refused.append((url, finalVerdict.reason ?? "Final safety check failed"))
                continue
            }
            guard FileIdentity(url) == approvedIdentity else {
                outcome.refused.append((url, "The item changed after it was reviewed"))
                continue
            }
            if let reason = Self.partialDownloadRefusal(for: url) {
                outcome.refused.append((url, reason))
                if stopAfterRefusal { break }
                continue
            }
            let reclaimableBytes =
                disposal == .delete
                ? Guarded.run(budget: 8) { FileSize.reclaimableSize(of: url) } ?? 0
                : 0
            if let reason = refusalBeforeDispose?(url) {
                outcome.refused.append((url, reason))
                if stopAfterRefusal { break }
                continue
            }
            let disposalVerdict = PathGuard.evaluate(url, allowUserRoots: allowUserRoots)
            guard disposalVerdict.isAllowed else {
                outcome.refused.append(
                    (url, disposalVerdict.reason ?? "Disposal safety check failed")
                )
                continue
            }
            guard FileIdentity(url) == approvedIdentity else {
                outcome.refused.append((url, "The item changed during final sizing"))
                continue
            }
            if let reason = Self.partialDownloadRefusal(for: url) {
                outcome.refused.append((url, reason))
                if stopAfterRefusal { break }
                continue
            }

            do {
                let disposed = try dispose(url, disposal: disposal)
                let usedTrash: Bool
                switch disposed {
                case let .trashed(location):
                    usedTrash = true
                    outcome.trashed += 1
                    if let location { outcome.trashedLocations.append(location) }
                case .deleted:
                    usedTrash = false
                }
                outcome.removed.append(url)
                outcome.bytesProcessed += measurement.bytes
                if !usedTrash { outcome.bytesFreed += reclaimableBytes }
                outcome.filesRemoved += max(1, measurement.fileCount)
                let entry = OperationLog.Entry(
                    path: url.path,
                    bytes: measurement.bytes,
                    recoverable: usedTrash,
                    date: Date()
                )
                outcome.historyEntries.append(entry)
                legacyHistory?.recordLegacy(entry)
            } catch {
                // A Trash request that could not be honoured is reported as a
                // failure, not quietly completed as a permanent deletion.
                let reason =
                    disposal == .trash
                    ? "Could not be moved to the Trash, so nothing was removed — "
                        + "\(error.localizedDescription)"
                    : error.localizedDescription
                outcome.failed.append((url, reason))
            }
        }

        return outcome
    }

    /// The outcome of disposing of a single item.
    private enum Disposed {
        /// Moved to the Trash, and recoverable from the returned location.
        case trashed(URL?)
        /// Unlinked. Only ever the result of an explicit `.delete` request.
        case deleted
    }

    /// Disposes of one item, or throws.
    ///
    /// A Trash request remains explicit and never falls through to deletion.
    /// ApexClean itself uses `.delete`; `.trash` remains only for ApexCore source
    /// compatibility.
    private func dispose(_ url: URL, disposal: Disposal) throws -> Disposed {
        // Items already in the Trash cannot be trashed again.
        let inTrash = Self.isInsideUserTrash(url)

        if disposal == .trash, !inTrash {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return .trashed(resulting as URL?)
        }

        try FileManager.default.removeItem(at: url)
        return .deleted
    }

    static func isInsideUserTrash(_ url: URL) -> Bool {
        let trashPath = PathGuard.home.appendingPathComponent(".Trash").standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == trashPath || path.hasPrefix(trashPath + "/")
    }

    static func isPartialDownload(_ url: URL) -> Bool {
        ["download", "crdownload", "part"].contains(url.pathExtension.lowercased())
    }

    private static func partialDownloadRefusal(for url: URL) -> String? {
        guard isPartialDownload(url) else { return nil }
        let lsof = "/usr/sbin/lsof"
        guard Shell.exists(lsof) else {
            return "Could not verify whether this partial download is still active"
        }

        var isDirectory: ObjCBool = false
        let directory =
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let arguments =
            directory
            ? ["-F", "n", "+D", url.path]
            : ["-F", "n", "--", url.path]
        let result = Shell.runDetailed(lsof, arguments, timeout: 4)
        if result.timedOut || result.status < 0 {
            return "Could not verify whether this partial download is still active"
        }
        if result.status == 0 {
            return "This partial download is still open in another process"
        }
        return result.status == 1 && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : "Could not verify whether this partial download is still active"
    }

    static func requiresDeveloperToolsIdle(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = [
            PathGuard.home.appendingPathComponent("Library/Developer/Xcode").path,
            PathGuard.home.appendingPathComponent("Library/Developer/CoreSimulator").path,
        ]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func developerToolsRefusal(
        for url: URL,
        runningExecutables: Set<String>? = nil
    ) -> String? {
        guard requiresDeveloperToolsIdle(url) else { return nil }
        let active: Set<String>
        if let runningExecutables {
            active = Set(runningExecutables.map { $0.lowercased() })
        } else {
            guard let output = Shell.run("/bin/ps", ["-axo", "comm="], timeout: 4) else {
                return "Could not verify whether developer tools are active"
            }
            active = Set(
                output.split(separator: "\n").map {
                    URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces))
                        .lastPathComponent
                        .lowercased()
                }
            )
        }
        let guarded = [
            "xcode", "xcodebuild", "xctest", "xctrunner", "swift-frontend",
            "simulator", "coresimulatorservice", "ibtoold",
        ]
        guard let process = guarded.first(where: active.contains) else { return nil }
        return "\(process) is active; developer build and simulator data was left untouched"
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let linkCount: nlink_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init?(_ url: URL) {
            var status = stat()
            guard lstat(url.path, &status) == 0 else { return nil }
            device = status.st_dev
            inode = status.st_ino
            mode = status.st_mode & mode_t(S_IFMT)
            size = status.st_size
            linkCount = status.st_nlink
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        }
    }

    /// Empties the user Trash. Separated from `remove` because the Trash is the
    /// one place where a direct unlink is the *only* correct disposal.
    ///
    /// Falls back to Finder when macOS will not let us list `~/.Trash`, which is
    /// the normal case: the Trash is Full Disk Access territory, and refusing to
    /// work at all would be a worse answer than asking Finder to do it.
    @discardableResult
    /// - Parameter alreadyCounted: Trash locations this run just created. They
    ///   are still erased, but contribute no bytes and no second history entry,
    ///   because moving a file to the Trash and then emptying it reclaims its
    ///   space once. Counting both inflated a real 1.24 GB clean to "3.02 GB",
    ///   and `totalReclaimed()` carried the error forever.
    public func emptyTrash(
        alreadyCounted: [URL] = [],
        progress: ((Int, Int) -> Void)? = nil
    ) -> Outcome {
        let trash = PathGuard.home.appendingPathComponent(".Trash")

        // The Trash is erased with a direct unlink, so the one structural
        // assumption behind that — it is a real directory in this home folder,
        // not a link pointing somewhere else — is checked rather than assumed.
        // Mole refuses the same case (`lib/core/file_ops.sh:1055-1057`).
        guard let values = try? trash.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            var refused = Outcome()
            refused.refused.append((trash, "The Trash is not a regular directory"))
            return refused
        }

        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: trash,
                includingPropertiesForKeys: nil,
                options: []
            )
        else { return Self.emptyTrashViaFinder() }

        let counted = Set(alreadyCounted.map { $0.standardizedFileURL.path })
        let measured = contents.map { url in
            (
                url: url,
                measurement: FileSize.measure(url),
                alreadyCounted: counted.contains(url.standardizedFileURL.path)
            )
        }
        var outcome = Self.emptyTrashViaFinder()
        guard outcome.failed.isEmpty else { return outcome }

        for (index, item) in measured.enumerated() {
            defer { progress?(index + 1, measured.count) }
            outcome.removed.append(item.url)
            outcome.bytesFreed += item.measurement.bytes
            guard !item.alreadyCounted else { continue }
            outcome.filesRemoved += item.measurement.fileCount
            outcome.bytesProcessed += item.measurement.bytes
            outcome.historyEntries.append(
                .init(
                    path: item.url.path,
                    bytes: item.measurement.bytes,
                    recoverable: false,
                    date: Date()
                )
            )
        }
        return outcome
    }

    /// Asks Finder to empty the Trash. Finder already holds the access we lack,
    /// and it handles the parts we could not do correctly anyway — per-volume
    /// `.Trashes` directories and items locked by another process.
    ///
    /// The exact byte count is unknowable this way, so nothing is invented: the
    /// outcome reports success without claiming a figure it cannot support.
    private static func emptyTrashViaFinder() -> Outcome {
        var outcome = Outcome()
        outcome.usedFinder = true
        let result = Shell.runDetailed(
            "/usr/bin/osascript",
            ["-e", "tell application \"Finder\" to empty the trash"],
            timeout: 300
        )
        if !result.succeeded {
            outcome.failed.append(
                (
                    PathGuard.home.appendingPathComponent(".Trash"),
                    result.lastMeaningfulLine ?? "Finder could not empty the Trash"
                ))
        }
        return outcome
    }

    /// What ApexClean can currently say about the Trash.
    public enum TrashState: Equatable, Sendable {
        case empty
        case holding(bytes: Int64, items: Int)
        /// macOS refuses to list `~/.Trash` without Full Disk Access, and it
        /// refuses outright rather than prompting. Reporting this as "empty"
        /// would be a confident lie, so it gets its own state.
        case unreadable
    }

    public static func inspectTrash() -> TrashState {
        let trash = PathGuard.home.appendingPathComponent(".Trash")
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: trash,
                includingPropertiesForKeys: nil,
                options: []
            )
        else { return .unreadable }

        let visible = contents.filter { $0.lastPathComponent != ".DS_Store" }
        guard !visible.isEmpty else { return .empty }
        let bytes = visible.reduce(0) { $0 + FileSize.measure($1).bytes }
        return .holding(bytes: bytes, items: visible.count)
    }
}
