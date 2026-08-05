import Foundation

/// Fast on-disk size measurement.
///
/// Uses allocated size (what the volume actually gives up when the file is
/// removed) rather than logical size, so the number we promise the user matches
/// the number they get back.
public enum FileSize {
    private static let allocationKeys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .linkCountKey,
    ]

    public struct Measurement {
        public var bytes: Int64
        public var fileCount: Int
        public init(bytes: Int64 = 0, fileCount: Int = 0) {
            self.bytes = bytes
            self.fileCount = fileCount
        }

        public static func + (lhs: Measurement, rhs: Measurement) -> Measurement {
            Measurement(bytes: lhs.bytes + rhs.bytes, fileCount: lhs.fileCount + rhs.fileCount)
        }
    }

    /// Counts a file with more than one link exactly once per walk.
    ///
    /// Without this, a hardlinked tree is charged once per link: Homebrew's
    /// Cellar measured 4.655 GB against `du`'s 4.517 GB, the whole 138 MB gap
    /// being 258 duplicate links, and a pnpm store linked into several projects
    /// reports its size once per project. Deleting one copy then frees far less
    /// than promised. Mole keys the same set on `(st_dev, st_ino)`
    /// (`cmd/analyze/scanner.go:1069-1087`).
    final class HardlinkSet: @unchecked Sendable {
        private struct Key: Hashable {
            let device: dev_t
            let inode: ino_t
        }

        private let lock = NSLock()
        private var seen = Set<Key>()

        /// True when this entry's bytes should be counted.
        ///
        /// The link count comes from resource values that were already
        /// fetched, so the `lstat` is only paid for the small minority of
        /// files that can actually be reached twice.
        func admit(_ values: URLResourceValues, at url: URL) -> Bool {
            guard let links = values.linkCount, links > 1 else { return true }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return true }
            lock.lock()
            defer { lock.unlock() }
            return seen.insert(Key(device: info.st_dev, inode: info.st_ino)).inserted
        }
    }

    public static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    /// Recursively measures a path. `isCancelled` is polled often enough that a
    /// user-initiated stop feels immediate even inside a huge directory.
    public static func measure(
        _ url: URL,
        isCancelled: () -> Bool = { false }
    ) -> Measurement {
        measure(url, hardlinks: HardlinkSet(), isCancelled: isCancelled)
    }

    static func measure(
        _ url: URL,
        hardlinks: HardlinkSet,
        isCancelled: () -> Bool = { false }
    ) -> Measurement {
        // The measured directory is itself the root here, so an opaque root that
        // contains it must not blank the result.
        let scanRoot = url
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return Measurement() }

        // Never follow a symlink into unrelated storage; the link itself is all we own.
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true
        {
            return Measurement(bytes: allocatedSize(of: url), fileCount: 1)
        }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: allocationKeys)
            guard let values, hardlinks.admit(values, at: url) else { return Measurement() }
            return Measurement(
                bytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                fileCount: 1
            )
        }

        var result = Measurement()
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: Array(allocationKeys),
                options: [],
                errorHandler: { _, _ in true }
            )
        else {
            return result
        }

        // Measuring must never wander onto another volume or into a
        // provider-backed store: both can block on a read that has no deadline,
        // and neither is space that removing this path would give back.
        let fence = Traversal.VolumeFence(root: url)
        for case let child as URL in enumerator {
            if isCancelled() { break }

            if !fence.admits(child) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? child.resourceValues(forKeys: allocationKeys) else { continue }
            let isChildDirectory = values.isDirectory == true

            // An opaque container is not walked into — reading it can block on
            // a provider with no deadline — but it is still *measured*, from the
            // outside. Skipping it outright contributed zero, which made
            // `~/Pictures` report 9.78 MB against a true 4.38 GB because the
            // Photos library inside it simply vanished from the total. A
            // silently under-reported parent is worse than an omitted one: it
            // still looks measured.
            if isChildDirectory, Traversal.isOpaqueContainer(child, scanRoot: scanRoot) {
                enumerator.skipDescendants()
                result = result + outsideMeasure(of: child, isCancelled: isCancelled)
                continue
            }

            if isChildDirectory { continue }
            guard hardlinks.admit(values, at: child) else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            result.bytes += size
            result.fileCount += 1
        }
        return result
    }

    /// Measures a directory that must not be walked into, using `du`.
    ///
    /// `du` is a separate process with its own deadline, so a provider-backed
    /// store that would park an in-process enumerator forever costs a bounded
    /// wait instead. `-s` for the total, `-k` because the output is KiB.
    private static func outsideMeasure(of url: URL, isCancelled: () -> Bool) -> Measurement {
        guard !isCancelled() else { return Measurement() }
        let result = Shell.runDetailed("/usr/bin/du", ["-skx", url.path], timeout: 8)
        guard !result.timedOut,
            let field = result.output.split(separator: "\n").first?
                .split(separator: "\t").first,
            let kilobytes = Int64(field.trimmingCharacters(in: .whitespaces))
        else {
            // Better an honest floor than a zero: the container itself is at
            // least as big as its own directory entry.
            return Measurement(bytes: allocatedSize(of: url), fileCount: 1)
        }
        return Measurement(bytes: kilobytes * 1024, fileCount: 1)
    }

    /// Cheap top-level entry count, capped so a directory with a million entries
    /// cannot stall a scan just to answer "is there anything in here?".
    public static func hasEntries(_ url: URL) -> Bool {
        guard
            let iterator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        else { return false }
        return iterator.nextObject() != nil
    }
}
