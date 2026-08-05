import XCTest

@testable import ApexCore

/// Covers the rules that keep a scan from wandering somewhere it can never
/// return from. These are the guards behind a hang that left Space Lens
/// spinning forever, so they are worth pinning down precisely.
final class TraversalTests: XCTestCase {

    // MARK: - Opaque containers

    func testManagedLibrariesAreOpaque() {
        let cases = [
            "/Users/x/Pictures/Photos Library.photoslibrary",
            "/Users/x/Music/Music Library.musiclibrary",
            "/Users/x/Movies/Home.imovielibrary",
            "/Users/x/Archive.sparsebundle",
        ]
        for path in cases {
            XCTAssertTrue(
                Traversal.isOpaqueContainer(URL(fileURLWithPath: path)),
                "\(path) should never be opened by a scan"
            )
        }
    }

    func testProviderBackedHomeFoldersAreOpaque() {
        XCTAssertTrue(
            Traversal.isOpaqueContainer(
                URL(fileURLWithPath: "/Users/x/Library/Mobile Documents")))
        XCTAssertTrue(
            Traversal.isOpaqueContainer(
                URL(fileURLWithPath: "/Users/x/Library/CloudStorage/Dropbox")))
    }

    /// The rule that caused the original loose-matching bug: a folder a person
    /// actually owns must not be excluded because its name collides with a
    /// synthetic mount point.
    func testOrdinaryFoldersNamedLikeMountPointsAreNotOpaque() {
        let innocuous = [
            "/Users/x/Developer/project/home",
            "/Users/x/Developer/home/assets",
            "/Users/x/net",
            "/Users/x/Documents/Volumes",
        ]
        for path in innocuous {
            XCTAssertFalse(
                Traversal.isOpaqueContainer(URL(fileURLWithPath: path)),
                "\(path) is a normal user folder and must still be measured"
            )
        }
    }

    func testSyntheticRootsAreOpaque() {
        XCTAssertTrue(Traversal.isOpaqueContainer(URL(fileURLWithPath: "/home")))
        XCTAssertTrue(Traversal.isOpaqueContainer(URL(fileURLWithPath: "/net/server/share")))
        XCTAssertTrue(Traversal.isOpaqueContainer(URL(fileURLWithPath: "/System/Volumes/VM")))
    }

    /// The Data volume holds the user's files; excluding it would exclude
    /// everything worth measuring.
    func testDataVolumeIsNotOpaque() {
        XCTAssertFalse(
            Traversal.isOpaqueContainer(
                URL(fileURLWithPath: "/System/Volumes/Data/Users/x")))
    }

    // MARK: - Volume fence

    func testFenceAdmitsPathsOnTheSameVolume() {
        let home = PathGuard.home
        let fence = Traversal.VolumeFence(root: home)
        XCTAssertTrue(fence.admits(home))
        XCTAssertTrue(fence.admits(home.appendingPathComponent("Library")))
    }

    /// Preboot is a separate APFS volume from the Data volume that holds a home
    /// directory. (The System and Data volumes are a *volume group* and report
    /// as one, which is why they are not used here.)
    func testFenceRejectsAnotherVolume() throws {
        let fence = Traversal.VolumeFence(root: PathGuard.home)
        let other = URL(fileURLWithPath: "/System/Volumes/Preboot")
        guard let homeVolume = Traversal.volumeIdentifier(of: PathGuard.home),
            let otherVolume = Traversal.volumeIdentifier(of: other),
            !homeVolume.isEqual(otherVolume)
        else {
            throw XCTSkip("No separate volume available to fence against")
        }
        XCTAssertFalse(fence.admits(other))
    }

    func testFenceRejectsPathsItCannotIdentify() {
        let fence = Traversal.VolumeFence(root: PathGuard.home)
        XCTAssertFalse(fence.admits(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
    }

    func testFenceFailsClosedWhenRootVolumeCannotBeIdentified() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fence = Traversal.VolumeFence(root: missingRoot)
        XCTAssertFalse(fence.admits(FileManager.default.temporaryDirectory))
    }
}

/// Behaviour of the tree walk itself.
final class SpaceScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apexclean-space-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// A package is a directory whose own allocated size is a few kilobytes of
    /// metadata. Reporting that number instead of measuring the contents made
    /// every application on the Mac look empty in the treemap.
    func testPackagesAreMeasuredNotReportedAsMetadata() throws {
        let bundle = root.appendingPathComponent("Sample.app")
        try write(400_000, to: bundle.appendingPathComponent("Contents/MacOS/Sample"))

        let node = SpaceScanner().scan(root: root)
        let app = try XCTUnwrap(node?.children.first { $0.name == "Sample" })
        XCTAssertTrue(app.isDirectory, "A package should read as one item, not a file")
        XCTAssertGreaterThanOrEqual(app.bytes, 400_000)
    }

    func testQuarantinedPathsAreNotVisited() throws {
        try write(300_000, to: root.appendingPathComponent("keep/data.bin"))
        try write(300_000, to: root.appendingPathComponent("skip/data.bin"))

        let skipped = root.appendingPathComponent("skip").path
        let node = SpaceScanner(skipping: [skipped]).scan(root: root)

        XCTAssertNil(node?.children.first { $0.name == "skip" })
        XCTAssertNotNil(node?.children.first { $0.name == "keep" })
    }

    /// Directory enumeration reports `/private/var/…` while a path built in
    /// code says `/var/…`. A skip list that compares them literally silently
    /// does nothing, which is exactly the failure mode a recovery path must not
    /// have.
    func testQuarantineMatchesEitherSpellingOfAPath() throws {
        try write(300_000, to: root.appendingPathComponent("skip/data.bin"))
        let asWritten = root.appendingPathComponent("skip").path
        let asEnumerated = "/private" + asWritten
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: asEnumerated),
            "Test needs a path the file system exposes under two names"
        )

        for spelling in [asWritten, asEnumerated] {
            let node = SpaceScanner(skipping: [spelling]).scan(root: root)
            XCTAssertNil(
                node?.children.first { $0.name == "skip" },
                "Quarantine missed when the path was given as \(spelling)"
            )
        }
    }

    func testHeartbeatAdvancesWhileScanning() throws {
        for index in 0..<12 {
            try write(1_000, to: root.appendingPathComponent("dir\(index)/file.bin"))
        }
        let scanner = SpaceScanner()
        XCTAssertEqual(scanner.heartbeat, 0)
        _ = scanner.scan(root: root)
        XCTAssertGreaterThan(
            scanner.heartbeat, 12,
            "The watchdog relies on this counter to tell a slow scan from a wedged one"
        )
    }

    func testStalledPathNamesSomethingUseful() throws {
        try write(1_000, to: root.appendingPathComponent("a/file.bin"))
        let scanner = SpaceScanner()
        _ = scanner.scan(root: root)
        XCTAssertTrue(
            Traversal.canonical(scanner.stalledPath)
                .hasPrefix(Traversal.canonical(root.path)),
            "The in-flight path is what the stall message shows the user"
        )
    }

    func testCancellationBeforeAQueuedScanStartsIsSticky() throws {
        try write(64, to: root.appendingPathComponent("folder/file.bin"))
        let scanner = SpaceScanner()
        scanner.cancel()
        XCTAssertNil(scanner.scan(root: root))
    }

    /// Stop must actually stop after a walk has begun as well.
    func testCancellingDuringAScanStopsTheWalk() throws {
        for index in 0..<140 {
            try write(64, to: root.appendingPathComponent("dir\(index)/file.bin"))
        }
        let scanner = SpaceScanner()
        var sawProgress = false
        let node = scanner.scan(root: root) { _ in
            sawProgress = true
            scanner.cancel()
        }
        XCTAssertTrue(sawProgress, "Test tree was too small to reach a progress callback")
        XCTAssertNil(node)
    }

    func testSymlinksAreNotFollowed() throws {
        try write(500_000, to: root.appendingPathComponent("real/data.bin"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("real"))

        let node = try XCTUnwrap(SpaceScanner().scan(root: root))
        let linkNode = try XCTUnwrap(node.children.first { $0.name == "link" })
        XCTAssertEqual(linkNode.bytes, 0, "Following the link would double-count the same storage")
    }
}

/// The worker that makes an unresponsive folder survivable.
final class GuardedDirectoryListerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apexclean-lister-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListsAnOrdinaryDirectory() throws {
        for name in ["a", "b", "c"] {
            try Data(count: 8).write(to: root.appendingPathComponent(name))
        }
        let contents = try XCTUnwrap(
            GuardedDirectoryLister().contents(
                of: root, includingPropertiesForKeys: []))
        XCTAssertEqual(Set(contents.map(\.lastPathComponent)), ["a", "b", "c"])
    }

    func testMissingDirectoryReportsEmptyRatherThanTimingOut() {
        let lister = GuardedDirectoryLister()
        let missing = root.appendingPathComponent("nope")
        XCTAssertEqual(lister.contents(of: missing, includingPropertiesForKeys: [])?.count, 0)
        XCTAssertTrue(lister.abandonedPaths.isEmpty, "A plain failure is not a stall")
    }

    /// The property the whole design exists for: after a listing overruns its
    /// budget, the *next* listing must still work. A wedged job left on a
    /// shared serial queue would block every request behind it forever.
    func testRemainsUsableAfterATimeout() throws {
        let lister = GuardedDirectoryLister()
        try Data(count: 8).write(to: root.appendingPathComponent("kept"))

        // A zero budget guarantees the timeout path is taken.
        XCTAssertNil(
            lister.contents(
                of: root, includingPropertiesForKeys: [], budget: 0))
        XCTAssertEqual(lister.abandonedPaths.count, 1)

        let recovered = try XCTUnwrap(
            lister.contents(
                of: root, includingPropertiesForKeys: []))
        XCTAssertEqual(recovered.map(\.lastPathComponent), ["kept"])
    }

    func testAbandonedPathsAreCappedSoTheyStayReportable() {
        let lister = GuardedDirectoryLister()
        for _ in 0..<60 {
            _ = lister.contents(of: root, includingPropertiesForKeys: [], budget: 0)
        }
        XCTAssertLessThanOrEqual(lister.abandonedPaths.count, 24)
        XCTAssertFalse(lister.abandonedPaths.isEmpty)
    }
}
