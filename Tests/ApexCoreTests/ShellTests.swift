import Darwin
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

    func testClosedParentStandardOutputCannotStealTheCaptureDescriptor() {
        let savedOutput = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(savedOutput, 0)
        guard savedOutput >= 0 else { return }

        let output: String? = {
            fflush(stdout)
            _ = close(STDOUT_FILENO)
            defer { _ = dup2(savedOutput, STDOUT_FILENO) }
            return Shell.run("/bin/echo", ["still captured"])
        }()
        _ = close(savedOutput)

        XCTAssertEqual(
            output?.trimmingCharacters(in: .whitespacesAndNewlines),
            "still captured"
        )
    }

    func testInvalidUTF8FailsClosedForSamplingButRemainsVisibleInDetailedOutput() {
        let command = ["-c", "printf '\\377'"]
        XCTAssertNil(Shell.run("/bin/sh", command))

        let detailed = Shell.runDetailed("/bin/sh", command)
        XCTAssertTrue(detailed.succeeded)
        XCTAssertFalse(detailed.output.isEmpty)
    }

    func testTimeoutTerminatesInsteadOfHanging() {
        let started = Date()
        _ = Shell.run("/bin/sleep", ["30"], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTimeoutDoesNotReturnPartialOutputWhenChildClosesItsPipe() {
        let started = Date()
        let output = Shell.run(
            "/bin/sh",
            ["-c", "echo partial; exec 1>&-; sleep 30"],
            timeout: 0.3
        )
        XCTAssertNil(output)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
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

    func testTimeoutTerminatesAChildReparentedAfterShellExit() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }

        _ = Shell.runDetailed(
            "/bin/sh",
            ["-c", "sleep 30 & echo $! > '\(pidFile.path)'"],
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
            "The orphaned child remained active in state \(state ?? "?")"
        )
    }

    func testTimeoutTerminatesAChildThatEscapesIntoANewSession() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("Perl is unavailable on this host")
        }
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            setsid();
            $SIG{TERM} = "IGNORE";
            open(my $fh, ">", "\(pidFile.path)") or die;
            print $fh "$$\\n";
            close($fh);
            sleep 30;
            """

        _ = Shell.runDetailed(
            "/bin/sh",
            ["-c", "/usr/bin/perl -MPOSIX=setsid -e '\(script)' &"],
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
            "The session-escaping child remained active in state \(state ?? "?")"
        )
    }

    func testDoubleForkedChildWithClosedOutputCannotEscapeSupervision() throws {
        try assertDoubleForkIsContained()
    }

    func testSupervisionAvoidsAnOccupiedDescriptor198() throws {
        var descriptors: [Int32] = []
        while fcntl(198, F_GETFD) == -1 {
            let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { break }
            descriptors.append(descriptor)
        }
        defer { descriptors.forEach { close($0) } }
        XCTAssertGreaterThanOrEqual(fcntl(198, F_GETFD), 0)

        try assertDoubleForkIsContained()
    }

    private func assertDoubleForkIsContained() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("Perl is unavailable on this host")
        }
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
            defined(my $first = fork()) or die;
            exit 0 if $first;
            setsid();
            defined(my $second = fork()) or die;
            exit 0 if $second;
            open(my $fh, ">", "\(pidFile.path)") or die;
            print $fh "$$\\n";
            close($fh);
            open(STDIN, "<", "/dev/null");
            open(STDOUT, ">", "/dev/null");
            open(STDERR, ">", "/dev/null");
            $SIG{TERM} = "IGNORE";
            sleep 30;
            """

        let result = Shell.runDetailed(
            "/usr/bin/perl",
            ["-MPOSIX=setsid", "-e", script],
            timeout: 2
        )

        XCTAssertTrue(result.timedOut)
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
            "The double-forked child remained active in state \(state ?? "?")"
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

    func testConcurrentCommandCannotInheritAnotherCommandsCapturePipe() {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let output = LockedString()
        let shortDone = DispatchSemaphore(value: 0)
        let longDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            output.set(
                Shell.run(
                    "/bin/sh",
                    ["-c", "echo ready > '\(marker.path)'; sleep 0.2; echo short"],
                    timeout: 0.8
                )
            )
            shortDone.signal()
        }

        let markerDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < markerDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        DispatchQueue.global().async {
            _ = Shell.run("/bin/sleep", ["1.5"], timeout: 2)
            longDone.signal()
        }

        XCTAssertEqual(shortDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            output.get()?.trimmingCharacters(in: .whitespacesAndNewlines),
            "short"
        )
        XCTAssertEqual(longDone.wait(timeout: .now() + 3), .success)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ newValue: String?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
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
