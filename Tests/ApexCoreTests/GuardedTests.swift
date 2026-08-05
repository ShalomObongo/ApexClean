import XCTest

@testable import ApexCore

/// `Guarded` exists so a syscall that blocks in the kernel cannot take a
/// feature with it. The contract worth pinning down is the timeout: the caller
/// must come back, with `nil`, at roughly the budget — not when the work
/// eventually finishes.
final class GuardedTests: XCTestCase {
    func testReturnsValueWhenWorkFinishesInTime() {
        XCTAssertEqual(Guarded.run(budget: 5) { 41 + 1 }, 42)
    }

    func testReturnsNilWhenWorkExceedsBudget() {
        let started = Date()
        let result: Int? = Guarded.run(budget: 0.2) {
            Thread.sleep(forTimeInterval: 3)
            return 7
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.5, "the caller must not wait for abandoned work")
    }

    func testAbandonedWorkDoesNotPoisonLaterCalls() {
        _ = Guarded.run(budget: 0.1) { Thread.sleep(forTimeInterval: 2) }
        // A shared serial queue would leave the wedged job at the head and
        // swallow this one. A fresh thread per call must not.
        XCTAssertEqual(Guarded.run(budget: 5) { "ok" }, "ok")
    }

    func testPropagatesOptionalResults() {
        let value: String?? = Guarded.run(budget: 5) { String?.none }
        XCTAssertNotNil(value as Any?, "the outer optional means 'timed out', not 'nil result'")
        XCTAssertNil(value ?? "unexpected")
    }
}

final class UninstallPlanTests: XCTestCase {
    private func sampleApp(path: String, name: String, bundleID: String) -> InstalledApp {
        InstalledApp(
            url: URL(fileURLWithPath: path),
            name: name,
            bundleID: bundleID,
            version: "1.0",
            bundleBytes: 0,
            lastUsed: nil,
            installed: nil,
            isRunning: false,
            isSystem: false,
            source: .direct
        )
    }

    private func leftover(_ path: String, bytes: Int64, unknown: Bool) -> Leftover {
        Leftover(
            url: URL(fileURLWithPath: path),
            bytes: bytes,
            kind: .containers,
            evidence: "test",
            sizeIsUnknown: unknown
        )
    }

    func testLeftoverSizeIsKnownByDefault() {
        let item = Leftover(
            url: URL(fileURLWithPath: "/tmp/a"), bytes: 10, kind: .caches, evidence: "test"
        )
        XCTAssertFalse(item.sizeIsUnknown)
    }

    func testUnmeasurableSelectsOnlyUnknownSizes() {
        let plan = UninstallPlan(
            app: sampleApp(
                path: "/Applications/Test.app", name: "Test", bundleID: "fit.apexclean.test"
            ),
            bundle: URL(fileURLWithPath: "/Applications/Test.app"),
            leftovers: [
                leftover("/tmp/known", bytes: 100, unknown: false),
                leftover("/tmp/gated", bytes: 0, unknown: true),
            ]
        )

        XCTAssertEqual(plan.unmeasurable.count, 1)
        XCTAssertEqual(plan.unmeasurable.first?.url.lastPathComponent, "gated")
        XCTAssertEqual(plan.leftoverBytes, 100, "an unmeasurable item must not invent a size")
    }

    /// The regression this file was written for: an app with a sandbox
    /// container used to wedge `plan(for:)` inside `open()` forever, because
    /// measuring `~/Library/Containers/<id>` blocks without Full Disk Access.
    func testPlanReturnsPromptlyForAnAppWithASandboxContainer() {
        let app = sampleApp(
            path: "/System/Applications/Notes.app", name: "Notes", bundleID: "com.apple.Notes"
        )

        let started = Date()
        let plan = LeftoverFinder.plan(for: app)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 60, "leftover discovery must be bounded, not open-ended")
        XCTAssertTrue(
            plan.leftovers.allSatisfy { !$0.sizeIsUnknown || $0.bytes == 0 },
            "an unmeasured item must report zero rather than a guess"
        )
    }
}
