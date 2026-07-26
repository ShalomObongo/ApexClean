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
                let usedTrash = try dispose(url, disposal: disposal)
                outcome.removed.append(url)
                outcome.bytesReclaimed += measurement.bytes
                outcome.filesRemoved += max(1, measurement.fileCount)
                if usedTrash { outcome.trashed += 1 }
                history?.record(
                    .init(
                        path: url.path,
                        bytes: measurement.bytes,
                        recoverable: usedTrash,
                        date: Date()
                    )
                )
            } catch {
                outcome.failed.append((url, error.localizedDescription))
            }
        }

        return outcome
    }

    /// Returns true when the item landed in the Trash and is therefore recoverable.
    private func dispose(_ url: URL, disposal: Disposal) throws -> Bool {
        // Items already in the Trash cannot be trashed again.
        let inTrash = url.path.hasPrefix(PathGuard.home.appendingPathComponent(".Trash").path)

        if disposal == .trash, !inTrash {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return true
            } catch {
                // Trash can legitimately fail (other volumes, no .Trashes). Fall
                // through to a direct unlink only for targets we already vouched for.
                Log.safety.notice("Trash unavailable for \(url.path, privacy: .public), removing directly")
            }
        }

        try FileManager.default.removeItem(at: url)
        return false
    }

    /// Empties the user Trash. Separated from `remove` because the Trash is the
    /// one place where a direct unlink is the *only* correct disposal.
    ///
    /// Falls back to Finder when macOS will not let us list `~/.Trash`, which is
    /// the normal case: the Trash is Full Disk Access territory, and refusing to
    /// work at all would be a worse answer than asking Finder to do it.
    @discardableResult
    public func emptyTrash(progress: ((Int, Int) -> Void)? = nil) -> Outcome {
        let trash = PathGuard.home.appendingPathComponent(".Trash")
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: trash,
                includingPropertiesForKeys: nil,
                options: []
            )
        else {
            return Self.emptyTrashViaFinder()
        }

        var outcome = Outcome()
        for (index, url) in contents.enumerated() {
            defer { progress?(index + 1, contents.count) }
            let measurement = FileSize.measure(url)
            do {
                try FileManager.default.removeItem(at: url)
                outcome.removed.append(url)
                outcome.bytesReclaimed += measurement.bytes
                outcome.filesRemoved += max(1, measurement.fileCount)
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
