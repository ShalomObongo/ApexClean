import Foundation
import XCTest

@testable import ApexCore

final class HardlinkAccountingTests: XCTestCase {
    func testSpaceScannerCountsHardlinkedAllocationOnce() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data(repeating: 0x1, count: 1_000_000).write(to: first)
        try FileManager.default.linkItem(at: first, to: second)

        let measured = FileSize.measure(first).bytes
        let node = try XCTUnwrap(SpaceScanner().scan(root: root))
        XCTAssertEqual(node.bytes, measured)
    }

    func testLargeFileFinderReturnsOneEntryPerHardlinkedInode() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data(repeating: 0x2, count: 128_000).write(to: first)
        try FileManager.default.linkItem(at: first, to: second)

        let matches = LargeFileFinder.find(in: root, minimumBytes: 1)
        XCTAssertEqual(matches.count, 1)
    }

    func testSharedCleanupMeasurementRegistryCountsHardlinkOnceAcrossItems() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data(repeating: 0x3, count: 128_000).write(to: first)
        try FileManager.default.linkItem(at: first, to: second)

        let registry = FileSize.HardlinkSet()
        let firstSize = FileSize.measure(first, hardlinks: registry).bytes
        let secondSize = FileSize.measure(second, hardlinks: registry).bytes
        XCTAssertGreaterThan(firstSize, 0)
        XCTAssertEqual(secondSize, 0)
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
