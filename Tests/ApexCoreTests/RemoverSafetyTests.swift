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

    func testDirectoryDeletionCountsReclaimableContents() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data(repeating: 0xA5, count: 32_768)
            .write(to: directory.appendingPathComponent("payload.bin"))
        let reclaimable = FileSize.reclaimableSize(of: directory)

        let outcome = Remover().remove([directory], disposal: .delete)

        XCTAssertGreaterThan(reclaimable, 0)
        XCTAssertEqual(outcome.bytesFreed, reclaimable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDirectoryDeletionDoesNotClaimAnExternallyLinkedFileWasFreed() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = parent.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let external = parent.appendingPathComponent("external.bin")
        let linked = directory.appendingPathComponent("linked.bin")
        try Data(repeating: 0xA5, count: 32_768).write(to: external)
        try FileManager.default.linkItem(at: external, to: linked)

        let outcome = Remover().remove([directory], disposal: .delete)

        XCTAssertGreaterThan(outcome.bytesProcessed, 0)
        XCTAssertEqual(outcome.bytesFreed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testOpenFileInsideDownloadDirectoryBlocksDeletion() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let download = parent.appendingPathComponent("Safari.download", isDirectory: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let payload = download.appendingPathComponent("payload")
        try Data("active".utf8).write(to: payload)
        let handle = try FileHandle(forReadingFrom: payload)

        let refused = Remover().remove([download], disposal: .delete)
        XCTAssertTrue(refused.removed.isEmpty)
        XCTAssertNotNil(refused.refused.first?.reason)

        try handle.close()
        let removed = Remover().remove([download], disposal: .delete)
        XCTAssertEqual(removed.removed, [download])
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

        let remover = Remover(beforeDispose: { url in
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: replacement)
        })
        let outcome = remover.remove([target], disposal: .delete)

        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(outcome.refused.first?.reason, "The item changed after it was reviewed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testReplacementDuringFinalSizingIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let replacement = directory.appendingPathComponent("replacement")
        try Data("original".utf8).write(to: target)
        try Data("replacement".utf8).write(to: replacement)
        let calls = LockedCounter()

        let remover = Remover(
            refusalBeforeDispose: { url in
                if calls.increment() == 3 {
                    try? FileManager.default.removeItem(at: url)
                    try? FileManager.default.createSymbolicLink(
                        at: url,
                        withDestinationURL: replacement
                    )
                }
                return nil
            }
        )
        let outcome = remover.remove([target], disposal: .delete)

        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(outcome.refused.first?.reason, "The item changed during final sizing")
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

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            value += 1
            defer { lock.unlock() }
            return value
        }
    }
}
