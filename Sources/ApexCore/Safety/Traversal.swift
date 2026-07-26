import Foundation

/// Rules that decide which directories a scan is allowed to walk into.
///
/// Every recursive walk in ApexClean goes through here, because a single
/// unresponsive `open()` is enough to wedge a scan forever: the syscall blocks
/// in the kernel, cancellation flags are never read again, and — if the work is
/// on a serial queue — every later scan queues up behind a thread that will
/// never return. A disk analyser that silently stops working after touching one
/// bad folder is worse than one that admits it skipped it.
///
/// The rules below are all *pre-open* checks. Once `open()` has blocked there is
/// no way back, so the only real defence is to not open the thing at all.
public enum Traversal {

    // MARK: - Path identity

    /// Resolves a path to the form the file system reports.
    ///
    /// Directory enumeration hands back fully resolved paths
    /// (`/private/var/…`), while a path assembled in code keeps whatever the
    /// caller wrote (`/var/…`). Comparing the two forms directly makes set
    /// membership miss, which would quietly defeat a skip list.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Volume boundaries

    /// Opaque token identifying the volume a URL lives on, or `nil` if it cannot
    /// be determined (in which case callers should treat it as foreign).
    public static func volumeIdentifier(of url: URL) -> NSObject? {
        let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
        return values?.volumeIdentifier as? NSObject
    }

    /// `du -x` semantics: a scan measures one volume and does not wander onto
    /// another.
    ///
    /// This is the single highest-value guard. Automounts (`/home` via autofs),
    /// network shares, disk images, FileProvider mounts and cloud-sync
    /// placeholders all present as a *different* volume, and all of them can
    /// block indefinitely on the first read while the provider is asked to
    /// materialise something. Staying on the boot volume removes that entire
    /// class of hang, and it is also the honest answer — space on another
    /// volume is not space you reclaim by cleaning this one.
    public struct VolumeFence {
        private let rootVolume: NSObject?

        public init(root: URL) {
            self.rootVolume = Traversal.volumeIdentifier(of: root)
        }

        public func admits(_ url: URL) -> Bool {
            guard let rootVolume else { return true }
            guard let volume = Traversal.volumeIdentifier(of: url) else { return false }
            return volume.isEqual(rootVolume)
        }
    }

    // MARK: - Opaque containers

    /// Bundle extensions that are a *managed store*, not a folder of files.
    ///
    /// Reading inside these hands control to a daemon (`photolibraryd`,
    /// `Music`, `fileproviderd`), which may need to fault content in from
    /// iCloud, rebuild an index, or ask TCC for consent first. Any of those can
    /// take minutes or never finish. They are measured from the outside instead.
    private static let opaqueExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary",
        "musiclibrary", "tvlibrary", "itlp",
        "imovielibrary", "theater", "fcpbundle", "lrdata", "lrcat",
        "sparsebundle", "sparseimage", "dmg",
    ]

    /// Path fragments that lead into provider-backed storage, matched relative
    /// to any home directory.
    ///
    /// `Mobile Documents` and `CloudStorage` are iCloud Drive and third-party
    /// FileProvider roots: enumerating them can trigger downloads that have no
    /// deadline.
    private static let opaqueSuffixes: [String] = [
        "/Library/Mobile Documents",
        "/Library/CloudStorage",
        "/Library/Application Support/CloudDocs",
        "/Library/Daemon Containers",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.DocumentRevisions-V100",
        "/.TemporaryItems",
    ]

    /// Absolute locations that are synthetic, automounted, or system-managed.
    ///
    /// These are anchored to the start of the path on purpose: matching them
    /// loosely would exclude any ordinary folder that happens to be named
    /// `home` or `net`, which people do have.
    private static let opaqueRoots: [String] = [
        "/Network",
        "/net",
        "/home",
        "/Volumes",
        "/private/var/vm",
        "/System/Volumes/VM",
        "/System/Volumes/Preboot",
        "/System/Volumes/Update",
        "/System/Volumes/xarts",
        "/System/Volumes/iSCPreboot",
        "/System/Volumes/Hardware",
    ]

    /// True when the directory should be sized from the outside rather than
    /// walked into.
    public static func isOpaqueContainer(_ url: URL) -> Bool {
        if opaqueExtensions.contains(url.pathExtension.lowercased()) { return true }
        let path = url.path
        for root in opaqueRoots where path == root || path.hasPrefix(root + "/") {
            return true
        }
        for suffix in opaqueSuffixes where path.hasSuffix(suffix) || path.contains(suffix + "/") {
            return true
        }
        return false
    }
}
