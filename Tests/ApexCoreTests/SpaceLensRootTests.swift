import XCTest

@testable import ApexCore

/// Space Lens maps whatever folder it is handed. These are the cases where it
/// used to return an empty or near-empty map with no error at all.
final class SpaceLensRootTests: XCTestCase {
    /// `/Volumes` is opaque so that mapping `/` does not wander onto every
    /// mounted disk — but that rule must not fire on the volume the user
    /// explicitly chose, or an external drive maps as 0 bytes.
    func testChoosingAVolumeAsTheRootDoesNotMakeItsContentsOpaque() {
        let volume = URL(fileURLWithPath: "/Volumes/SomeDrive")
        let child = URL(fileURLWithPath: "/Volumes/SomeDrive/Users")

        XCTAssertTrue(
            Traversal.isOpaqueContainer(child),
            "without a scan root, /Volumes must stay opaque so mapping / stays on one disk"
        )
        XCTAssertFalse(
            Traversal.isOpaqueContainer(child, scanRoot: volume),
            "the volume the user asked to map must be walkable"
        )
    }

    /// The exception is only for an opaque root that *contains* the scan root.
    /// One below it still applies.
    func testOpaqueRootsBelowTheScanRootStillApply() {
        let root = URL(fileURLWithPath: "/")
        for path in ["/Volumes/Other", "/private/var/vm", "/System/Volumes/VM", "/Network"] {
            XCTAssertTrue(
                Traversal.isOpaqueContainer(URL(fileURLWithPath: path), scanRoot: root),
                "\(path) must stay opaque when mapping /"
            )
        }
    }

    /// Extension-based opacity is independent of the scan root: a Photos
    /// library is measured from the outside wherever it is found.
    func testExtensionOpacityIsUnaffectedByTheScanRoot() {
        let library = URL(fileURLWithPath: "/Volumes/SomeDrive/Pictures/Photos Library.photoslibrary")
        XCTAssertTrue(
            Traversal.isOpaqueContainer(library, scanRoot: URL(fileURLWithPath: "/Volumes/SomeDrive"))
        )
    }
}

/// A container that is not walked into must still be counted. Reporting zero
/// for it is worse than omitting it, because the parent still looks measured.
final class OpaqueContainerSizingTests: XCTestCase {
    func testExplicitOpaqueRootIsMeasuredWithoutBuildingChildren() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = parent.appendingPathComponent("Library.photoslibrary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("originals", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data(repeating: 0xA5, count: 32_768)
            .write(to: library.appendingPathComponent("originals/photo.bin"))

        let node = try XCTUnwrap(SpaceScanner().scan(root: library))

        XCTAssertGreaterThan(node.bytes, 0)
        XCTAssertTrue(node.children.isEmpty)
    }

    final class LargeFileAliasTests: XCTestCase {
        func testSymlinkedRootFindsTheSameFileExactlyOnce() throws {
            let parent = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let real = parent.appendingPathComponent("real", isDirectory: true)
            let alias = parent.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            let file = real.appendingPathComponent("large.bin")
            try Data(repeating: 0xA5, count: 32_768).write(to: file)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

            let realMatches = LargeFileFinder.find(in: real, minimumBytes: 1)
            let aliasMatches = LargeFileFinder.find(in: alias, minimumBytes: 1)

            XCTAssertEqual(realMatches.count, 1)
            XCTAssertEqual(aliasMatches.map(\.url.path), realMatches.map(\.url.path))
            XCTAssertEqual(realMatches.first?.url.lastPathComponent, "large.bin")
        }
    }

    func testAMeasuredFolderIncludesContainersItRefusesToWalkInto() throws {
        let pictures = PathGuard.home.appendingPathComponent("Pictures")
        guard FileManager.default.fileExists(atPath: pictures.path) else {
            throw XCTSkip("no ~/Pictures on this machine")
        }
        // Only meaningful if there is actually an opaque container inside.
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: pictures, includingPropertiesForKeys: nil)) ?? []
        guard contents.contains(where: { Traversal.isOpaqueContainer($0) }) else {
            throw XCTSkip("no opaque container in ~/Pictures")
        }

        let measured = FileSize.measure(pictures)
        let truth = Self.duBytes(pictures)
        guard truth > 0 else { throw XCTSkip("du produced no figure") }

        // Within 5%: `du` and the allocated-size walk round differently, but a
        // dropped Photos library was a 99.8% shortfall, not a rounding gap.
        let ratio = Double(measured.bytes) / Double(truth)
        XCTAssertGreaterThan(
            ratio, 0.95,
            "measured \(Bytes.format(measured.bytes)) against du's \(Bytes.format(truth))"
        )
    }

    private static func duBytes(_ url: URL) -> Int64 {
        guard let output = Shell.run("/usr/bin/du", ["-skx", url.path], timeout: 60),
            let field = output.split(separator: "\n").first?.split(separator: "\t").first,
            let kilobytes = Int64(field.trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return kilobytes * 1024
    }
}
