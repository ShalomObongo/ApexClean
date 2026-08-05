import Foundation
import XCTest

@testable import ApexCore

final class GlobTests: XCTestCase {
    func testIntermediateSymlinkDirectoriesAreNeverFollowed() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        XCTAssertTrue(Glob.expand("\(root.path)/*/*").isEmpty)
    }

    func testLimitIsDeterministicAndActuallyBoundsResults() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["e", "c", "a", "d", "b"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }

        XCTAssertEqual(
            Glob.expand("\(root.path)/*", limit: 3).map(\.lastPathComponent),
            ["a", "b", "c"]
        )
    }

    func testWildcardDoesNotImplicitlyIncludeHiddenFiles() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try Data().write(to: root.appendingPathComponent("visible"))

        XCTAssertEqual(
            Glob.expand("\(root.path)/*").map(\.lastPathComponent),
            ["visible"]
        )
        XCTAssertEqual(
            Glob.expand("\(root.path)/.*").map(\.lastPathComponent),
            [".hidden"]
        )
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
