import XCTest
@testable import ApexCore

final class CleanupCatalogTests: XCTestCase {
    func testCatalogIsSubstantialAndWellFormed() {
        let rules = CleanupCatalog.all
        XCTAssertGreaterThan(rules.count, 300, "Catalog should cover a broad set of vendors")

        for rule in rules {
            XCTAssertFalse(rule.title.isEmpty, "Every rule needs a human-readable title")
            XCTAssertTrue(
                rule.pattern.hasPrefix("~/") || rule.pattern.hasPrefix("/"),
                "Pattern must be absolute or home-relative: \(rule.pattern)"
            )
            XCTAssertFalse(
                rule.pattern.contains("//"),
                "Malformed pattern: \(rule.pattern)"
            )
        }
    }

    func testRuleIdentifiersAreUnique() {
        let ids = CleanupCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate rule identifiers would collide in selection state")
    }

    /// No rule may target a directory PathGuard would refuse, otherwise the UI
    /// would offer the user something the engine then declines to remove.
    func testNoRuleTargetsAProtectedRoot() {
        let refusedRoots = [
            PathGuard.home.path,
            PathGuard.home.path + "/Library",
            PathGuard.home.path + "/Library/Caches",
            PathGuard.home.path + "/Library/Application Support",
            "/Library",
            "/System",
        ]
        for rule in CleanupCatalog.all {
            let expanded = rule.pattern.expandingTilde
            // Strip the trailing glob to get the directory the rule operates in.
            let base = expanded.hasSuffix("/*") ? String(expanded.dropLast(2)) : expanded
            XCTAssertFalse(
                refusedRoots.contains(base),
                "Rule '\(rule.title)' targets protected root \(base)"
            )
        }
    }

    func testDefaultSelectedCategoriesAreConservative() {
        // Anything that could remove something a user still wants must be
        // opt-in, not preselected.
        for category in CleanupCategory.allCases {
            switch category {
            case .userCaches, .appLogs, .systemJunk, .browserData:
                XCTAssertTrue(category.isDefaultSelected, "\(category) should be recommended")
            case .developerJunk, .aiTools, .leftovers, .installers, .trash:
                XCTAssertFalse(category.isDefaultSelected, "\(category) must be opt-in")
            }
        }
    }

    func testRunningAppBlockersAreDeclaredForBrowsers() {
        // Removing a Chromium cache under a live browser corrupts its profile.
        let browserRules = CleanupCatalog.all.filter { $0.category == .browserData }
        let withBlockers = browserRules.filter { !$0.requiresQuit.isEmpty }
        XCTAssertGreaterThan(
            withBlockers.count,
            browserRules.count / 2,
            "Most browser cache rules should declare a quit requirement"
        )
    }

    func testEveryCategoryHasPresentationMetadata() {
        for category in CleanupCategory.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.subtitle.isEmpty)
            XCTAssertFalse(category.symbol.isEmpty)
        }
    }
}

final class BytesFormattingTests: XCTestCase {
    func testFormatsAcrossMagnitudes() {
        XCTAssertEqual(Bytes.format(0), "0 B")
        XCTAssertEqual(Bytes.format(512), "512 B")
        XCTAssertEqual(Bytes.format(1024), "1.00 KB")
        XCTAssertEqual(Bytes.format(1024 * 1024), "1.00 MB")
        XCTAssertEqual(Bytes.format(1024 * 1024 * 1024), "1.00 GB")
    }

    func testPrecisionDropsAsMagnitudeGrows() {
        XCTAssertEqual(Bytes.format(1_500 * 1024), "1.46 MB")
        XCTAssertEqual(Bytes.format(15_000 * 1024), "14.6 MB")
        XCTAssertEqual(Bytes.format(150_000 * 1024), "146 MB")
    }

    func testNegativeValuesClampToZero() {
        XCTAssertEqual(Bytes.format(-1), "0 B")
    }

    func testPartsSplitValueAndUnit() {
        let parts = Bytes.parts(1024 * 1024)
        XCTAssertEqual(parts.value, "1.00")
        XCTAssertEqual(parts.unit, "MB")
    }
}
