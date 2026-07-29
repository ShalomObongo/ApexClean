import Foundation

/// Performs removals. Prefers the Trash so every action stays recoverable, and
/// re-validates through `PathGuard` at the final boundary rather than trusting a
/// decision made earlier during the scan.
public final class Remover {
    public struct Outcome {
        public var removed: [URL] = []
        public var refused: [(url: URL, reason: String)] = []
        public var failed: [(url: URL, error: String)] = []
        public var bytesReclaimed: Int64 = 0
        public var filesRemoved: Int = 0
        public var trashed: Int = 0
        /// Where trashed items ended up.
        ///
        /// Kept so a Trash sweep in the same run can delete this pass's own
        /// items without charging for them a second time: moving a file to the
        /// Trash and then emptying it frees the space once, not twice.
        public var trashedLocations: [URL] = []

        public var isEmpty: Bool { removed.isEmpty && refused.isEmpty && failed.isEmpty }
    }

    public enum Disposal {
        /// Move to Trash. Recoverable, and the default everywhere it works.
        case trash
        /// Unlink directly. Only for content the Trash cannot hold (items already
        /// inside `~/.Trash`, or targets on volumes without a Trash directory).
        case delete
    }

    private let history: OperationLog?

    public init(history: OperationLog? = nil) {
        self.history = history
    }

    @discardableResult
    public func remove(
        _ urls: [URL],
        disposal: Disposal = .trash,
        allowUserRoots: Bool = false,
        knownSizes: [URL: Int64] = [:],
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

            let measurement: FileSize.Measurement
            if let known = knownSizes[url] {
                measurement = FileSize.Measurement(bytes: known, fileCount: 1)
            } else {
                measurement = FileSize.measure(url)
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
                outcome.bytesReclaimed += measurement.bytes
                outcome.filesRemoved += max(1, measurement.fileCount)
                history?.record(
                    .init(
                        path: url.path,
                        bytes: measurement.bytes,
                        recoverable: usedTrash,
                        date: Date()
                    )
                )
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
    /// A failed `trashItem` used to fall through to `removeItem`, turning a
    /// request the user approved on the promise "you can put it back" into a
    /// permanent deletion — and saying nothing. That is worst on exactly the
    /// volumes where it fails: an external disk or a network share with no
    /// `.Trashes`, where the selection is likely to be the user's own files
    /// rather than caches. It now refuses, and the caller reports it.
    ///
    /// Mole behaves the same way: a failed trash is logged and skipped, never
    /// escalated to `rm` (`lib/core/file_ops.sh:839-859`).
    private func dispose(_ url: URL, disposal: Disposal) throws -> Disposed {
        // Items already in the Trash cannot be trashed again.
        let inTrash = url.path.hasPrefix(PathGuard.home.appendingPathComponent(".Trash").path)

        if disposal == .trash, !inTrash {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return .trashed(resulting as URL?)
        }

        try FileManager.default.removeItem(at: url)
        return .deleted
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: trash.path),
            attributes[.type] as? FileAttributeType == .typeDirectory
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
        else {
            return Self.emptyTrashViaFinder()
        }

        let counted = Set(alreadyCounted.map { $0.standardizedFileURL.path })
        var outcome = Outcome()
        for (index, url) in contents.enumerated() {
            defer { progress?(index + 1, contents.count) }
            let isDoubleCount = counted.contains(url.standardizedFileURL.path)
            let measurement =
                isDoubleCount
                ? FileSize.Measurement(bytes: 0, fileCount: 0)
                : FileSize.measure(url)
            do {
                try FileManager.default.removeItem(at: url)
                outcome.removed.append(url)
                outcome.bytesReclaimed += measurement.bytes
                outcome.filesRemoved += measurement.fileCount
                if isDoubleCount { continue }
                // Recorded like any other removal. History is where people go to
                // find out what happened, and an unlogged deletion is the one
                // kind this app should never perform.
                history?.record(
                    .init(
                        path: url.path,
                        bytes: measurement.bytes,
                        recoverable: false,
                        date: Date()
                    )
                )
            } catch {
                outcome.failed.append((url, error.localizedDescription))
            }
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
    public enum TrashState: Equatable {
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
