import XCTest
@testable import ApexCore

/// The uninstaller decides what belongs to an app. Over-matching here means
/// deleting a different vendor's data, so the boundary rules get direct tests.
final class LeftoverMatchingTests: XCTestCase {
    func testBundleBoundaryMatchesExactAndDotExtended() {
        XCTAssertTrue(LeftoverFinder.hasBundleBoundary("com.example.app", "com.example.app"))
        XCTAssertTrue(LeftoverFinder.hasBundleBoundary("com.example.app.helper", "com.example.app"))
        XCTAssertTrue(LeftoverFinder.hasBundleBoundary("com.example.app.Extension", "com.example.app"))
    }

    func testBundleBoundaryRejectsUnrelatedVendorWithSharedPrefix() {
        // The bug this prevents: uninstalling "com.foo" sweeping up "com.foobar".
        XCTAssertFalse(LeftoverFinder.hasBundleBoundary("com.example.application", "com.example.app"))
        XCTAssertFalse(LeftoverFinder.hasBundleBoundary("com.example.appstore", "com.example.app"))
        XCTAssertFalse(LeftoverFinder.hasBundleBoundary("com.other.app", "com.example.app"))
    }

    func testBundleBoundaryMatchesTeamPrefixedGroupContainers() {
        // Group containers are commonly "<TEAMID>.group.<bundle-id>" or
        // "<TEAMID>.<bundle-id>".
        XCTAssertTrue(
            LeftoverFinder.hasBundleBoundary("8C7439RJLG.codes.rambo.AirBuddy", "codes.rambo.AirBuddy")
        )
        XCTAssertFalse(
            LeftoverFinder.hasBundleBoundary("8C7439RJLG.codes.rambo.AirBuddyPro", "codes.rambo.AirBuddy")
        )
    }

    func testRejectsMalformedBundleIdentifiers() {
        // A bundle id containing glob metacharacters or separators must never
        // reach a `find -name` style pattern.
        for identifier in ["", "app", "com", "a.b", "com.example/*", "com.*", "../etc"] {
            XCTAssertFalse(
                LeftoverFinder.isReverseDNS(identifier),
                "\(identifier) must not be treated as a usable bundle id"
            )
        }
    }

    func testAcceptsWellFormedBundleIdentifiers() {
        for identifier in ["com.example.app", "codes.rambo.AirBuddy", "dev.zed.Zed-Nightly"] {
            XCTAssertTrue(LeftoverFinder.isReverseDNS(identifier), identifier)
        }
    }

    func testNameVariantsCoverCommonDirectoryConventions() {
        let variants = Set(LeftoverFinder.nameVariants("Maestro Studio"))
        XCTAssertTrue(variants.contains("Maestro Studio"))
        XCTAssertTrue(variants.contains("MaestroStudio"))
        XCTAssertTrue(variants.contains("Maestro-Studio"))
        XCTAssertTrue(variants.contains("Maestro_Studio"))
        XCTAssertTrue(variants.contains("Maestro"), "Base name should be covered for versioned apps")
    }

    func testSingleWordNamesProduceNoSpuriousVariants() {
        XCTAssertEqual(Set(LeftoverFinder.nameVariants("Spotify")), ["Spotify"])
    }
}
