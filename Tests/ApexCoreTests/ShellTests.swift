import XCTest

@testable import ApexCore

/// `Shell.run` is the primitive under every process-backed reading in the app,
/// and it was changed to stop using `waitUntilExit()` — which pumps the caller's
/// run loop and re-enters AppKit when invoked from the main thread. These tests
/// pin the behaviour that change had to preserve.
final class ShellTests: XCTestCase {
    func testCapturesStandardOutput() {
        let output = Shell.run("/bin/echo", ["hello apexclean"])
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "hello apexclean")
    }

    func testReadsOutputLargerThanOnePipeBuffer() {
        // A 64 KB pipe fills long before a chatty child exits. If the reader and
        // the wait were ever serialised the wrong way round, this deadlocks.
        let output = Shell.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero | tr '\\0' 'a'"], timeout: 10)
        XCTAssertEqual(output?.count, 1_000_000)
    }

    func testTimeoutTerminatesInsteadOfHanging() {
        let started = Date()
        _ = Shell.run("/bin/sleep", ["30"], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testDetailedTimeoutEscalatesPastIgnoredTerminateSignal() {
        let started = Date()
        let result = Shell.runDetailed(
            "/bin/sh",
            ["-c", "trap '' TERM; while :; do sleep 1; done"],
            timeout: 0.3
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testTimeoutTerminatesDescendantProcesses() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        _ = Shell.runDetailed(
            "/bin/sh",
            ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"],
            timeout: 0.5
        )

        let raw = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(raw))
        let state = Shell.run(
            "/bin/ps",
            ["-p", "\(pid)", "-o", "stat="],
            timeout: 2
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            state == nil || state?.isEmpty == true || state?.hasPrefix("Z") == true,
            "The timed-out command left an active child process in state \(state ?? "?")"
        )
    }

    func testMissingExecutableReturnsNil() {
        XCTAssertNil(Shell.run("/definitely/not/a/binary", []))
    }

    func testNonZeroExitStillReturnsWhatWasWritten() {
        let output = Shell.run("/bin/sh", ["-c", "echo partial; exit 3"])
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "partial")
    }

    func testWhichOnlyResolvesTrustedRoots() {
        XCTAssertNotNil(Shell.which("sh"))
        XCTAssertNil(Shell.which("almost-certainly-not-installed-xyz"))
    }

    func testConcurrentCallsDoNotInterfere() {
        let results = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let value = Shell.run("/bin/echo", ["run-\(index)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock()
            results.add(value ?? "nil")
            lock.unlock()
        }
        XCTAssertEqual(Set(results as! [String]), Set((0..<8).map { "run-\($0)" }))
    }
}

final class CountFormattingTests: XCTestCase {
    func testGroupsPluralisation() {
        XCTAssertEqual(Count.groups(0), "0 groups")
        XCTAssertEqual(Count.groups(1), "1 group")
        XCTAssertEqual(Count.groups(2), "2 groups")
    }

    func testFilesAndItemsPluralisation() {
        XCTAssertEqual(Count.files(1), "1 file")
        XCTAssertEqual(Count.files(9), "9 files")
        XCTAssertEqual(Count.items(1), "1 item")
        XCTAssertEqual(Count.items(0), "0 items")
    }
}
