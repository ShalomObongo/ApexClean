import XCTest

@testable import ApexCore

final class RemoverSafetyTests: XCTestCase {
    func testTrashContainmentUsesAPathComponentBoundary() {
        let trash = PathGuard.home.appendingPathComponent(".Trash")

        XCTAssertTrue(Remover.isInsideUserTrash(trash.appendingPathComponent("item")))
        XCTAssertTrue(Remover.isInsideUserTrash(trash.appendingPathComponent("folder/item")))

        XCTAssertFalse(
            Remover.isInsideUserTrash(
                PathGuard.home.appendingPathComponent(".TrashBackup/photo.mov")
            )
        )
        XCTAssertFalse(
            Remover.isInsideUserTrash(
                PathGuard.home.appendingPathComponent(".Trash-old/file")
            )
        )
    }

    func testDirectDeletionCountsProcessedAndFreedBytesSeparately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("fixture.bin")
        try Data(repeating: 0xA5, count: 32_768).write(to: file)
        let known = FileSize.measure(file).bytes

        let outcome = Remover().remove(
            [file],
            disposal: .delete,
            knownSizes: [file: known]
        )

        XCTAssertEqual(outcome.bytesProcessed, known)
        XCTAssertEqual(outcome.bytesFreed, known)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(outcome.historyEntries.count, 1)
        XCTAssertFalse(outcome.historyEntries[0].recoverable)
    }

    func testPartialDownloadRecognitionIsExtensionBounded() {
        XCTAssertTrue(Remover.isPartialDownload(URL(fileURLWithPath: "/tmp/file.crdownload")))
        XCTAssertTrue(Remover.isPartialDownload(URL(fileURLWithPath: "/tmp/file.download")))
        XCTAssertTrue(Remover.isPartialDownload(URL(fileURLWithPath: "/tmp/file.part")))
        XCTAssertFalse(Remover.isPartialDownload(URL(fileURLWithPath: "/tmp/file.partial")))
        XCTAssertFalse(Remover.isPartialDownload(URL(fileURLWithPath: "/tmp/download")))
    }

    func testReplacementAfterReviewIsRefusedBeforeDeletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target")
        let replacement = directory.appendingPathComponent("replacement")
        try Data("original".utf8).write(to: target)
        try Data("replacement".utf8).write(to: replacement)

        let remover = Remover { url in
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: replacement)
        }
        let outcome = remover.remove([target], disposal: .delete)

        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(outcome.refused.first?.reason, "The item changed after it was reviewed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testDeveloperToolProcessesBlockDeveloperDataRemoval() {
        let derivedData = PathGuard.home
            .appendingPathComponent("Library/Developer/Xcode/DerivedData/App")
        XCTAssertTrue(Remover.requiresDeveloperToolsIdle(derivedData))
        XCTAssertNotNil(
            Remover.developerToolsRefusal(
                for: derivedData,
                runningExecutables: ["xcodebuild"]
            )
        )
        XCTAssertNil(
            Remover.developerToolsRefusal(
                for: derivedData,
                runningExecutables: ["Finder"]
            )
        )
        XCTAssertFalse(
            Remover.requiresDeveloperToolsIdle(
                PathGuard.home.appendingPathComponent("Library/Caches/Example")
            )
        )
    }
}
