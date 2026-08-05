import Darwin
import XCTest

@testable import ApexCore

/// Pruning keeps the map honest after a removal without re-measuring the whole
/// volume, so the arithmetic has to be exactly right — a wrong total here is a
/// lie told with confidence.
final class SpaceNodePruneTests: XCTestCase {
    private func tree() -> SpaceNode {
        let leafA = SpaceNode(
            url: URL(fileURLWithPath: "/tmp/root/branch/a"),
            name: "a", bytes: 300, isDirectory: false, modified: nil
        )
        let leafB = SpaceNode(
            url: URL(fileURLWithPath: "/tmp/root/branch/b"),
            name: "b", bytes: 200, isDirectory: false, modified: nil
        )
        let branch = SpaceNode(
            url: URL(fileURLWithPath: "/tmp/root/branch"),
            name: "branch", bytes: 500, isDirectory: true, modified: nil,
            children: [leafA, leafB]
        )
        return SpaceNode(
            url: URL(fileURLWithPath: "/tmp/root"),
            name: "root", bytes: 900, isDirectory: true, modified: nil,
            children: [branch]
        )
    }

    func testPruneRemovesTheChild() {
        let root = tree()
        let branch = root.children[0]
        branch.prune(branch.children[0])
        XCTAssertEqual(branch.children.map(\.name), ["b"])
    }

    func testPruneSubtractsFromEveryAncestor() {
        let root = tree()
        let branch = root.children[0]
        branch.prune(branch.children[0])
        XCTAssertEqual(branch.bytes, 200)
        XCTAssertEqual(root.bytes, 600)
    }

    func testPruneDetachesTheChildFromItsParent() {
        let root = tree()
        let branch = root.children[0]
        let leaf = branch.children[0]
        branch.prune(leaf)
        XCTAssertNil(leaf.parent)
    }

    func testPruningAnUnrelatedNodeChangesNothing() {
        let root = tree()
        let branch = root.children[0]
        let stranger = SpaceNode(
            url: URL(fileURLWithPath: "/tmp/elsewhere"),
            name: "elsewhere", bytes: 100, isDirectory: false, modified: nil
        )
        branch.prune(stranger)
        XCTAssertEqual(branch.bytes, 500)
        XCTAssertEqual(root.bytes, 900)
        XCTAssertEqual(branch.children.count, 2)
    }

    /// Reported sizes are estimates in places, so a child can be larger than the
    /// parent's recorded total. That must clamp, never wrap into a huge number.
    func testTotalsNeverGoNegative() {
        let child = SpaceNode(
            url: URL(fileURLWithPath: "/tmp/p/child"),
            name: "child", bytes: 900, isDirectory: false, modified: nil
        )
        let parent = SpaceNode(
            url: URL(fileURLWithPath: "/tmp/p"),
            name: "p", bytes: 100, isDirectory: true, modified: nil, children: [child]
        )
        parent.prune(child)
        XCTAssertEqual(parent.bytes, 0)
    }
}

/// `Shell.runDetailed` exists because an upgrade that failed must never be
/// reported as one that worked.
final class ShellDetailedTests: XCTestCase {
    func testReportsSuccessForExitZero() {
        let result = Shell.runDetailed("/bin/echo", ["hello"])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("hello"))
    }

    func testReportsFailureForNonZeroExit() {
        let result = Shell.runDetailed("/bin/sh", ["-c", "exit 3"])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status, 3)
    }

    func testReportsTheTerminatingSignal() {
        let result = Shell.runDetailed("/bin/sh", ["-c", "kill -TERM $$"])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status, SIGTERM)
    }

    /// Tools write their real complaint to stderr; discarding it leaves the user
    /// with a failure and no reason.
    func testCapturesStandardError() {
        let result = Shell.runDetailed("/bin/sh", ["-c", "echo trouble >&2; exit 1"])
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.output.contains("trouble"))
    }

    func testTimesOutRatherThanHanging() {
        let result = Shell.runDetailed("/bin/sleep", ["30"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testMissingExecutableIsAFailureNotACrash() {
        let result = Shell.runDetailed("/nope/not/here", [])
        XCTAssertFalse(result.succeeded)
    }

    func testLastMeaningfulLineSkipsProgressChatter() {
        let result = Shell.runDetailed(
            "/bin/sh",
            ["-c", "echo '==> Downloading'; echo 'Error: it broke'; exit 1"]
        )
        XCTAssertEqual(result.lastMeaningfulLine, "Error: it broke")
    }
}

/// The Trash is Full Disk Access territory: macOS refuses to list it outright
/// rather than prompting. "Cannot see it" and "it is empty" must never be
/// conflated, because the second is a claim and the first is an admission.
final class TrashStateTests: XCTestCase {
    func testStatesAreDistinguishable() {
        XCTAssertNotEqual(Remover.TrashState.empty, .unreadable)
        XCTAssertNotEqual(Remover.TrashState.holding(bytes: 1, items: 1), .empty)
        XCTAssertNotEqual(Remover.TrashState.holding(bytes: 1, items: 1), .unreadable)
    }

    func testHoldingCarriesBothSizeAndCount() {
        guard case let .holding(bytes, items) = Remover.TrashState.holding(bytes: 4096, items: 3) else {
            return XCTFail("expected holding")
        }
        XCTAssertEqual(bytes, 4096)
        XCTAssertEqual(items, 3)
    }

    /// Whatever this machine's Trash contains, inspection must return one of the
    /// three states and never crash or hang.
    func testInspectionAlwaysAnswers() {
        let state = Remover.inspectTrash()
        switch state {
        case .empty, .unreadable: break
        case let .holding(bytes, items):
            XCTAssertGreaterThan(items, 0)
            XCTAssertGreaterThanOrEqual(bytes, 0)
        }
    }
}
