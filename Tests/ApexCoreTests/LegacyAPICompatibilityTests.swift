import Foundation
import XCTest

@testable import ApexCore

@available(*, deprecated)
final class LegacyAPICompatibilityTests: XCTestCase {
    func testVersionOneHistoryAndRemoverAdaptersRemainUsable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = OperationLog(directory: directory)
        let remover = Remover(history: history)
        var outcome = Remover.Outcome()
        outcome.bytesReclaimed = 42

        history.record(
            .init(path: "/tmp/legacy", bytes: 1, recoverable: false, date: Date())
        )
        history.record(
            .init(path: "/tmp/legacy-2", bytes: 2, recoverable: false, date: Date())
        )

        XCTAssertEqual(outcome.bytesReclaimed, 42)
        let session = history.commitSession(title: "Legacy")
        XCTAssertEqual(session?.title, "Legacy")
        XCTAssertEqual(session?.itemCount, 2)
        XCTAssertEqual(Set(history.recentEntries().map(\.path)), ["/tmp/legacy", "/tmp/legacy-2"])
        _ = remover
    }

    func testVersionOneLargeFileCallbackAndHomebrewSymbolCompile() {
        let visit: () -> Void = {}
        _ = LargeFileFinder.find(
            in: FileManager.default.temporaryDirectory,
            minimumBytes: Int64.max,
            onVisit: visit
        )
        let forget: (String) -> Bool = HomebrewBridge.forgetCask
        _ = forget
    }

    func testVersionOneHistoryAggregatesRecordsAcrossThreads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = OperationLog(directory: directory)

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            history.record(
                .init(
                    path: "/tmp/legacy-\(index)",
                    bytes: 1,
                    recoverable: false,
                    date: Date()
                )
            )
        }

        let session = history.commitSession(title: "Combined")
        XCTAssertEqual(session?.title, "Combined")
        XCTAssertEqual(session?.itemCount, 2)
    }
}
