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
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return Measurement() }

        // Never follow a symlink into unrelated storage; the link itself is all we own.
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true
        {
            return Measurement(bytes: allocatedSize(of: url), fileCount: 1)
        }

        if !isDirectory.boolValue {
            return Measurement(bytes: allocatedSize(of: url), fileCount: 1)
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
            if Traversal.isOpaqueContainer(child) || !fence.admits(child) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? child.resourceValues(forKeys: allocationKeys) else { continue }
            if values.isDirectory == true { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            result.bytes += size
            result.fileCount += 1
        }
        return result
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
