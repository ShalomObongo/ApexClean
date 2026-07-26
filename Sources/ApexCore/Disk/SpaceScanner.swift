import Foundation
import AppKit

/// One node in the on-disk size tree.
public final class SpaceNode: Identifiable, Hashable {
    public let id: String
    public let url: URL
    public let name: String
    public var bytes: Int64
    public let isDirectory: Bool
    public let modified: Date?
    public private(set) var children: [SpaceNode]
    public weak var parent: SpaceNode?

    init(
        url: URL,
        name: String,
        bytes: Int64,
        isDirectory: Bool,
        modified: Date?,
        children: [SpaceNode] = []
    ) {
        self.id = url.path
        self.url = url
        self.name = name
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.modified = modified
        self.children = children
        for child in children { child.parent = self }
    }

    func adopt(_ nodes: [SpaceNode]) {
        children = nodes.sorted { $0.bytes > $1.bytes }
        for child in children { child.parent = self }
    }

    public var hasChildren: Bool { !children.isEmpty }

    /// Detaches a child and subtracts its size from every ancestor.
    ///
    /// Used after a removal so the map stays truthful without re-measuring the
    /// whole volume — a full rescan of a home folder takes minutes, which is an
    /// absurd price for having trashed one folder.
    public func prune(_ child: SpaceNode) {
        guard let index = children.firstIndex(where: { $0.id == child.id }) else { return }
        let freed = children[index].bytes
        children.remove(at: index)
        child.parent = nil

        var ancestor: SpaceNode? = self
        while let node = ancestor {
            node.bytes = max(0, node.bytes - freed)
            ancestor = node.parent
        }
    }

    public var breadcrumb: [SpaceNode] {
        var trail: [SpaceNode] = []
        var current: SpaceNode? = self
        while let node = current {
            trail.insert(node, at: 0)
            current = node.parent
        }
        return trail
    }

    public var fileKind: String {
        if isDirectory { return "Folder" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    public static func == (lhs: SpaceNode, rhs: SpaceNode) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Builds the size tree used by Space Lens.
///
/// Depth is bounded and children below a share threshold are folded into a
/// single "smaller items" node, because a treemap with ten thousand
/// one-pixel rectangles is noise, not information.
public final class SpaceScanner {
    public struct Progress {
        public var scannedPaths: Int
        public var currentPath: String
        public var bytesSeen: Int64
    }

    private var cancelled = false
    private let lock = NSLock()
    private var scanned = 0
    /// Bumped for every path touched, including files inside a bulk measure.
    /// A caller watching this can tell "slow" from "wedged", which no
    /// cancellation flag can do — a thread blocked in `open()` never gets to
    /// read a flag again.
    private var beats = 0
    /// The path currently being opened. Recorded *before* the read so that if
    /// the read never returns, the culprit is still nameable.
    private var inFlight = ""
    private var fence: Traversal.VolumeFence?
    private let lister = GuardedDirectoryLister()
    /// Paths a previous attempt proved unresponsive. Retrying without them is
    /// what turns a dead end into a recoverable one.
    private let skipped: Set<String>
    /// When false, Desktop/Documents/Downloads are skipped rather than walked,
    /// so mapping the Home folder cannot raise a privacy prompt on its own.
    private let includesProtectedLocations: Bool

    public init(includesProtectedLocations: Bool = false, skipping: Set<String> = []) {
        self.includesProtectedLocations = includesProtectedLocations
        self.skipped = Set(skipping.map(Traversal.canonical))
    }

    /// Membership test that tolerates the two spellings the file system uses for
    /// the same directory. The set is empty in the normal case, so the extra
    /// resolution only costs anything after a stall has actually happened.
    private func isQuarantined(_ path: String) -> Bool {
        guard !skipped.isEmpty else { return false }
        return skipped.contains(path) || skipped.contains(Traversal.canonical(path))
    }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Public read of the cancellation flag, for work that runs alongside the
    /// tree walk and should stop with it.
    public var isStopped: Bool { isCancelled }

    /// Lets adjacent work (the large-file pass) keep the same heartbeat alive,
    /// so the watchdog does not mistake it for a stall.
    public func noteProgress() { tick() }

    /// Monotonic counter of paths touched. Read from another thread to detect a
    /// stall.
    public var heartbeat: Int { lock.lock(); defer { lock.unlock() }; return beats }

    /// The path the scanner is waiting on right now. Meaningful precisely when
    /// the heartbeat has stopped.
    public var stalledPath: String { lock.lock(); defer { lock.unlock() }; return inFlight }

    /// Folders that never answered and were left out of the map. A disk map
    /// that silently omits storage is worse than one that says what it missed.
    public var unreadablePaths: [String] { lister.abandonedPaths }

    private func tick(_ path: String? = nil) {
        lock.lock()
        beats &+= 1
        if let path { inFlight = path }
        lock.unlock()
    }

    public func scan(
        root: URL,
        maxDepth: Int = 6,
        onProgress: ((Progress) -> Void)? = nil
    ) -> SpaceNode? {
        lock.lock()
        cancelled = false
        scanned = 0
        beats = 0
        inFlight = root.path
        lock.unlock()
        fence = Traversal.VolumeFence(root: root)
        let node = build(url: root, depth: 0, maxDepth: maxDepth, onProgress: onProgress)
        // A cancelled walk has measured only part of the tree. Returning it
        // would draw a treemap that looks authoritative while under-reporting
        // whatever came after the stop, so a stopped scan reports nothing.
        return isCancelled ? nil : node
    }

    private func build(
        url: URL,
        depth: Int,
        maxDepth: Int,
        onProgress: ((Progress) -> Void)?
    ) -> SpaceNode? {
        if isCancelled { return nil }

        // Everything below is checked *before* the first read of `url`, because
        // reading is what blocks, prompts, or downloads.
        if depth > 0 {
            if isQuarantined(url.path) { return nil }
            if !includesProtectedLocations, PrivacyAccess.requiresConsent(url.path) { return nil }
            // Another volume is another storage budget; walking onto one is both
            // misleading and the most common way to hit an unresponsive mount.
            if let fence, !fence.admits(url) { return nil }
        }

        tick(url.path)

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey, .contentModificationDateKey, .isPackageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let modified = values.contentModificationDate
        let name = displayName(for: url)

        // Symlinks are reported at their own size; following them would
        // double-count storage and can loop.
        if values.isSymbolicLink == true {
            return SpaceNode(url: url, name: name, bytes: 0, isDirectory: false, modified: modified)
        }

        guard values.isDirectory == true else {
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            return SpaceNode(url: url, name: name, bytes: bytes, isDirectory: false, modified: modified)
        }

        // An app bundle or a photo library reads as one thing to a user, and a
        // managed library must not be opened at all. Both are measured whole.
        // (Measuring matters: a directory's own `totalFileAllocatedSize` is a
        // few kilobytes of metadata, so treating a package as a file would
        // report every application on the Mac as approximately empty.)
        //
        // The opaque rule is skipped at depth 0: if the user explicitly chose
        // this folder — an external drive, say — that choice outranks a
        // heuristic meant to stop us wandering into one by accident.
        let isPackage = values.isPackage == true
        let isOpaque = depth > 0 && Traversal.isOpaqueContainer(url)
        if isPackage || isOpaque || depth >= maxDepth {
            let measurement = FileSize.measure(url, isCancelled: { self.tick(); return self.isCancelled })
            return SpaceNode(
                url: url,
                name: name,
                bytes: measurement.bytes,
                isDirectory: true,
                modified: modified
            )
        }

        scanned += 1
        if scanned % 64 == 0 {
            onProgress?(Progress(scannedPaths: scanned, currentPath: Glob.display(url.path), bytesSeen: 0))
        }

        // Deliberately budgeted rather than called directly: one unresponsive
        // folder must cost this branch of the walk, not the whole map.
        guard let contents = lister.contents(of: url, includingPropertiesForKeys: Array(keys)) else {
            return SpaceNode(
                url: url, name: name, bytes: 0, isDirectory: true, modified: modified
            )
        }

        var children: [SpaceNode] = []
        children.reserveCapacity(contents.count)
        for child in contents {
            if isCancelled { break }
            if let node = build(url: child, depth: depth + 1, maxDepth: maxDepth, onProgress: onProgress) {
                children.append(node)
            }
        }

        let total = children.reduce(Int64(0)) { $0 + $1.bytes }
        let node = SpaceNode(url: url, name: name, bytes: total, isDirectory: true, modified: modified)
        node.adopt(fold(children, total: total))
        return node
    }

    /// Collapses the long tail so a treemap stays legible.
    private func fold(_ children: [SpaceNode], total: Int64) -> [SpaceNode] {
        guard total > 0, children.count > 12 else { return children }
        let sorted = children.sorted { $0.bytes > $1.bytes }
        let threshold = Int64(Double(total) * 0.012)

        let kept = sorted.prefix { $0.bytes >= threshold }
        guard kept.count < sorted.count else { return sorted }

        let remainder = Array(sorted.dropFirst(kept.count))
        let remainderBytes = remainder.reduce(Int64(0)) { $0 + $1.bytes }
        guard remainderBytes > 0, remainder.count > 1 else { return sorted }

        let folded = SpaceNode(
            url: (kept.first?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"))
                .appendingPathComponent("·smaller-items"),
            name: "\(remainder.count) smaller items",
            bytes: remainderBytes,
            isDirectory: true,
            modified: nil
        )
        folded.adopt(remainder)
        return Array(kept) + [folded]
    }

    private func displayName(for url: URL) -> String {
        let raw = url.lastPathComponent
        if url.pathExtension == "app" { return url.deletingPathExtension().lastPathComponent }
        return raw.isEmpty ? url.path : raw
    }
}

/// Finds individually large files, which a treemap can bury inside a deep folder.
public enum LargeFileFinder {
    public struct Match: Identifiable, Hashable {
        public var id: String { url.path }
        public let url: URL
        public let bytes: Int64
        public let modified: Date?
        public var displayPath: String { Glob.display(url.deletingLastPathComponent().path) }
    }

    public static func find(
        in root: URL,
        minimumBytes: Int64 = 100 * 1024 * 1024,
        limit: Int = 200,
        includesProtectedLocations: Bool = false,
        skipping: Set<String> = [],
        onVisit: () -> Void = {},
        isCancelled: () -> Bool = { false }
    ) -> [Match] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let fence = Traversal.VolumeFence(root: root)
        var matches: [Match] = []
        for case let url as URL in enumerator {
            if isCancelled() { break }
            onVisit()
            // Same pre-read rules as the treemap walk: skip anything that can
            // prompt, fault in from a provider, or live on another volume.
            if skipping.contains(url.path)
                || (!includesProtectedLocations && PrivacyAccess.requiresConsent(url.path))
                || Traversal.isOpaqueContainer(url)
                || !fence.admits(url) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard bytes >= minimumBytes else { continue }
            matches.append(
                Match(url: url, bytes: bytes, modified: values.contentModificationDate)
            )
        }

        return Array(matches.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
