import XCTest

@testable import ApexCore

final class CleanupCatalogTests: XCTestCase {
    func testCatalogIsSubstantialAndWellFormed() {
        let rules = CleanupCatalog.all
        XCTAssertGreaterThan(rules.count, 300, "Catalog should cover a broad set of vendors")
        XCTAssertEqual(rules.count, 406, "Update documented catalog counts when rules change")

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
        XCTAssertEqual(
            Set(ids).count, ids.count, "Duplicate rule identifiers would collide in selection state")
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

    func testRiskyParityAuditRulesStayExcludedOrGuarded() {
        let rules = CleanupCatalog.all
        XCTAssertFalse(rules.contains { $0.pattern == "~/Library/Logs/*" })
        XCTAssertFalse(rules.contains { $0.pattern == "~/.pub-cache/*" })
        XCTAssertFalse(
            rules.contains {
                $0.pattern == "~/Library/Application Support/Claude/pending-uploads/*"
            }
        )

        let partialDownloads = rules.filter {
            ["download", "crdownload", "part"].contains(
                URL(fileURLWithPath: $0.pattern).pathExtension
            )
        }
        XCTAssertTrue(partialDownloads.allSatisfy { ($0.minimumAgeDays ?? 0) >= 1 })

        let developerRules = rules.filter {
            $0.pattern.contains("/Library/Developer/Xcode/")
                || $0.pattern.contains("/Library/Developer/CoreSimulator/")
        }
        XCTAssertFalse(developerRules.isEmpty)
        XCTAssertTrue(developerRules.allSatisfy { !$0.requiresQuit.isEmpty })
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
        XCTAssertEqual(Bytes.format(1_000), "1.00 KB")
        XCTAssertEqual(Bytes.format(1_000_000), "1.00 MB")
        XCTAssertEqual(Bytes.format(1_000_000_000), "1.00 GB")
    }

    /// Decimal units, so the figures reconcile with Finder and Disk Utility.
    func testUsesDecimalUnitsLikeMacOS() {
        // What Finder calls a 500 GB disk.
        XCTAssertEqual(Bytes.format(500_000_000_000), "500 GB")
        // A gibibyte is not a gigabyte, and must not be printed as one.
        XCTAssertEqual(Bytes.format(1 << 30), "1.07 GB")
    }

    /// The boundary used to fall through a gap: values from 1000 to 1023 were
    /// past the "print as bytes" cutoff but still divided by 1024, so 1000 B
    /// rendered as "0.98 KB".
    func testBoundaryBetweenBytesAndKilobytes() {
        XCTAssertEqual(Bytes.format(999), "999 B")
        XCTAssertEqual(Bytes.format(1_000), "1.00 KB")
        XCTAssertEqual(Bytes.format(1_023), "1.02 KB")
    }

    func testPrecisionDropsAsMagnitudeGrows() {
        XCTAssertEqual(Bytes.format(1_500_000), "1.50 MB")
        XCTAssertEqual(Bytes.format(15_000_000), "15.0 MB")
        XCTAssertEqual(Bytes.format(150_000_000), "150 MB")
    }

    func testNegativeValuesClampToZero() {
        XCTAssertEqual(Bytes.format(-1), "0 B")
    }

    func testPartsSplitValueAndUnit() {
        let parts = Bytes.parts(1_000_000)
        XCTAssertEqual(parts.value, "1.00")
        XCTAssertEqual(parts.unit, "MB")
    }
}

/// Paths that must never appear in the catalog.
///
/// Each of these was in it at some point and each is either irreplaceable or
/// enormously expensive to regenerate. Mole protects every one of them — most
/// through its default whitelist, Xcode Archives by only ever reporting them.
extension CleanupCatalogTests {
    func testCatalogExcludesIrreplaceableAndProtectedPaths() {
        let forbidden = [
            // dSYMs for shipped builds. Once gone, crash reports from that
            // release can never be symbolicated again.
            "~/Library/Developer/Xcode/Archives",
            // Model weights and browser binaries — hours of re-download.
            "~/.cache/huggingface",
            "~/Library/Caches/ms-playwright",
            // Can hold locally-installed artifacts that exist nowhere else.
            "~/.m2/repository",
            "~/.gradle/daemon",
            "~/.gradle/caches/build-cache",
            "~/Library/Caches/JetBrains",
        ]

        for path in forbidden {
            let matches = CleanupCatalog.all.filter { $0.pattern.hasPrefix(path) }
            XCTAssertTrue(
                matches.isEmpty,
                "\(path) is protected by Mole and must not be cleaned — found \(matches.map(\.title))"
            )
        }
    }

    /// Downloads and Desktop are where people keep things, not just where
    /// installers land. Mole only ever removes partial downloads there.
    func testCatalogDoesNotDeleteUserFilesFromDownloadsOrDesktop() {
        let allowedSuffixes = [".download", ".crdownload", ".part"]

        for rule in CleanupCatalog.all {
            for root in ["~/Downloads/", "~/Desktop/"] where rule.pattern.hasPrefix(root) {
                XCTAssertTrue(
                    allowedSuffixes.contains { rule.pattern.hasSuffix($0) },
                    "“\(rule.title)” (\(rule.pattern)) removes user files from \(root)"
                )
            }
        }
    }
}
