import Foundation
import XCTest

@testable import ApexCore

final class OperationLogTests: XCTestCase {
    func testConcurrentSessionsCannotStealEachOthersEntries() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = OperationLog(directory: directory)

        let first = OperationLog.Entry(
            path: "/tmp/first",
            bytes: 10,
            recoverable: true,
            date: Date()
        )
        let second = OperationLog.Entry(
            path: "/tmp/second",
            bytes: 20,
            recoverable: false,
            date: Date()
        )

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if index == 0 {
                _ = log.commitSession(title: "First", entries: [first])
            } else {
                _ = log.commitSession(title: "Second", entries: [second])
            }
        }

        let sessions = Dictionary(uniqueKeysWithValues: log.recentSessions().map { ($0.title, $0) })
        XCTAssertEqual(sessions["First"]?.bytes, 10)
        XCTAssertEqual(sessions["First"]?.itemCount, 1)
        XCTAssertEqual(sessions["Second"]?.bytes, 20)
        XCTAssertEqual(sessions["Second"]?.itemCount, 1)
        XCTAssertEqual(Set(log.recentEntries().map(\.path)), ["/tmp/first", "/tmp/second"])
    }

    func testCorruptStoreIsNeverOverwrittenByANewCommit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("history-v1.json")
        let corrupt = Data("{\"version\":1,\"entries\":[".utf8)
        try corrupt.write(to: store)

        let log = OperationLog(directory: directory)
        let entry = OperationLog.Entry(
            path: "/tmp/new",
            bytes: 1,
            recoverable: true,
            date: Date()
        )
        XCTAssertNil(log.commitSession(title: "Must fail", entries: [entry]))
        XCTAssertEqual(try Data(contentsOf: store), corrupt)
    }

    func testCommitMigratesLegacyFilesIntoOneAtomicStore() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldEntry = OperationLog.Entry(
            path: "/tmp/old",
            bytes: 4,
            recoverable: true,
            date: Date(timeIntervalSince1970: 1)
        )
        let oldSession = OperationLog.Session(
            title: "Old",
            date: Date(timeIntervalSince1970: 1),
            bytes: 4,
            itemCount: 1,
            recoverableCount: 1
        )
        try encode([oldEntry], to: directory.appendingPathComponent("operations.json"))
        try encode([oldSession], to: directory.appendingPathComponent("sessions.json"))

        let log = OperationLog(directory: directory)
        let newEntry = OperationLog.Entry(
            path: "/tmp/new",
            bytes: 8,
            recoverable: false,
            date: Date(timeIntervalSince1970: 2)
        )
        XCTAssertNotNil(log.commitSession(title: "New", entries: [newEntry]))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("history-v1.json").path
            )
        )
        XCTAssertEqual(log.totalProcessed(), 12)
        XCTAssertEqual(Set(log.recentEntries().map(\.path)), ["/tmp/old", "/tmp/new"])
    }

    func testStorePermissionsArePrivate() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = OperationLog(directory: directory)
        let entry = OperationLog.Entry(
            path: "/tmp/private",
            bytes: 1,
            recoverable: true,
            date: Date()
        )
        XCTAssertNotNil(log.commitSession(title: "Private", entries: [entry]))

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber
        )
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("history-v1.json").path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testSeparateInstancesDoNotOverwriteEachOther() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = OperationLog(directory: directory)
        let second = OperationLog(directory: directory)

        XCTAssertNotNil(
            first.commitSession(
                title: "First",
                entries: [
                    .init(path: "/tmp/first", bytes: 1, recoverable: true, date: Date())
                ]
            )
        )
        XCTAssertNotNil(
            second.commitSession(
                title: "Second",
                entries: [
                    .init(path: "/tmp/second", bytes: 2, recoverable: true, date: Date())
                ]
            )
        )

        XCTAssertEqual(Set(first.recentSessions().map(\.title)), ["First", "Second"])
        XCTAssertEqual(first.totalProcessed(), 3)
        XCTAssertEqual(first.totalSessionCount(), 2)
    }

    func testRecentDetailIsBoundedButLifetimeTotalsRemain() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = OperationLog(directory: directory)
        let entries = (0..<5_100).map {
            OperationLog.Entry(
                path: "/tmp/\($0)",
                bytes: 1,
                recoverable: true,
                date: Date()
            )
        }
        XCTAssertNotNil(log.commitSession(title: "Large", entries: entries))
        XCTAssertEqual(log.recentEntries(limit: 10_000).count, 5_000)
        XCTAssertEqual(log.totalProcessed(), 5_100)
        XCTAssertEqual(log.totalSessionCount(), 1)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url)
    }
}
