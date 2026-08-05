import Darwin
import Foundation
import XCTest

@testable import ApexCore

final class StartupInventoryTests: XCTestCase {
    func testMissingProgramOnUnmountedVolumeIsNotDeclaredOrphaned() throws {
        let url = try makePlist(
            label: "com.example.external",
            program: "/Volumes/ApexCleanDefinitelyMissing/Tools/helper"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = try XCTUnwrap(StartupInventory.describe(url, scope: .userAgent))
        XCTAssertFalse(item.isOrphaned)
    }

    func testMissingProgramOnAvailableVolumeIsOrphaned() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let url = try makePlist(label: "com.example.missing", program: missing)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = try XCTUnwrap(StartupInventory.describe(url, scope: .userAgent))
        XCTAssertTrue(item.isOrphaned)
    }

    func testUnloadRefusesPlistsOutsideTheUserLaunchAgentsDirectory() throws {
        let url = try makePlist(label: "com.example.agent", program: "/tmp/example")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertFalse(StartupInventory.unload(plist: url))
    }

    func testDescribeRefusesSymlinkedPlist() throws {
        let target = try makePlist(label: "com.example.target", program: "/tmp/example")
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let link = target.deletingLastPathComponent().appendingPathComponent("linked.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertNil(StartupInventory.describe(link, scope: .userAgent))
    }

    func testDescribeRefusesFIFOWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("blocked.plist")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let started = Date()
        XCTAssertNil(StartupInventory.describe(fifo, scope: .userAgent))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    private func makePlist(label: String, program: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("agent.plist")
        let value: [String: Any] = ["Label": label, "Program": program]
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        return url
    }
}
