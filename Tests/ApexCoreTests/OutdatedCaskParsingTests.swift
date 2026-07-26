import XCTest
@testable import ApexCore

/// The update list is a claim about the user's machine, so the parser is
/// tested for what it *refuses* to claim as much as for what it reports.
final class OutdatedCaskParsingTests: XCTestCase {
    func testParsesVersionedUpgrade() {
        let casks = HomebrewBridge.parseOutdatedCasks("docker (4.37.2,179585) != 4.83.0,234302")
        XCTAssertEqual(casks.count, 1)
        XCTAssertEqual(casks.first?.token, "docker")
        XCTAssertEqual(casks.first?.currentVersion, "4.37.2,179585")
        XCTAssertEqual(casks.first?.latestVersion, "4.83.0,234302")
    }

    /// `--greedy` returns `version :latest` casks as `latest != latest`.
    /// Homebrew cannot compare them, so neither can we.
    func testDropsUncomparableLatestEntries() {
        XCTAssertTrue(HomebrewBridge.parseOutdatedCasks("hyprnote (latest) != latest").isEmpty)
    }

    func testDropsEntriesWhoseVersionsAreIdentical() {
        XCTAssertTrue(HomebrewBridge.parseOutdatedCasks("thing (2.0) != 2.0").isEmpty)
    }

    func testIgnoresLinesThatAreNotUpgradeRecords() {
        let output = """
        ==> Casks
        not a record
        firefox (140.0) != 141.0
        """
        let casks = HomebrewBridge.parseOutdatedCasks(output)
        XCTAssertEqual(casks.map(\.token), ["firefox"])
    }

    /// Versions containing parentheses must not truncate the current version.
    func testUsesTheLastClosingParenthesis() {
        let casks = HomebrewBridge.parseOutdatedCasks("app (1.0 (build 9)) != 2.0")
        XCTAssertEqual(casks.first?.currentVersion, "1.0 (build 9)")
        XCTAssertEqual(casks.first?.latestVersion, "2.0")
    }

    func testRejectsRecordsWithAnEmptyToken() {
        XCTAssertTrue(HomebrewBridge.parseOutdatedCasks("(1.0) != 2.0").isEmpty)
    }
}

/// A wrong diagnosis is worse than none. An earlier version matched "quit"
/// loosely and reported "Quit the app first" for `invalid option:
/// --no-quarantine`, so these tests pin the failure wording down.
final class UpgradeFailureReportingTests: XCTestCase {
    private func failure(_ output: String) -> String {
        HomebrewBridge.describe(
            failure: Shell.Result(status: 1, output: output, timedOut: false)
        )
    }

    func testQuotesHomebrewsOwnErrorLine() {
        XCTAssertEqual(failure("==> Downloading\nError: invalid option: --no-quarantine"),
                       "invalid option: --no-quarantine")
    }

    func testDoesNotMistakeQuarantineForQuit() {
        XCTAssertFalse(failure("Error: invalid option: --no-quarantine").contains("Quit the app"))
    }

    func testRecognisesARunningApplication() {
        XCTAssertEqual(failure("Error: Prismlauncher is currently running"),
                       "Quit the app first, then try again.")
    }

    func testRecognisesAPasswordRequirement() {
        XCTAssertTrue(failure("Error: sudo: a password is required").contains("administrator password"))
    }

    func testFallsBackToTheLastLineWhenThereIsNoErrorPrefix() {
        XCTAssertEqual(failure("==> Downloading\nsomething went sideways"), "something went sideways")
    }

    func testPointsAtAppManagementForBlockedBundleWrites() {
        XCTAssertTrue(
            failure("Error: Operation not permitted @ /Applications/Thing.app")
                .contains("App Management")
        )
    }

    func testNeverReturnsAnEmptyMessage() {
        XCTAssertFalse(failure("").isEmpty)
    }
}
