import XCTest

@testable import ApexCore

/// Rules overlap. What must never happen is the same bytes being counted twice,
/// or a path being listed under two findings so that removing one silently
/// invalidates the other.
final class CleanupOverlapTests: XCTestCase {
    /// Static overlaps can erase stricter risk/category/quit metadata when a
    /// broad rule wins. Keep the shipped catalog unambiguous; the scanner's
    /// runtime deduplication remains a final defence for wildcard expansion.
    func testCatalogueHasNoStaticOverlaps() {
        let rules = CleanupCatalog.all
        let patterns = rules.map(\.pattern)

        var seen: [String: Int] = [:]
        for pattern in patterns { seen[pattern, default: 0] += 1 }
        let duplicated = seen.filter { $0.value > 1 }

        var nested = 0
        for pattern in patterns where pattern.hasSuffix("/*") {
            let base = String(pattern.dropLast(2))
            nested += patterns.filter { $0 != pattern && $0.hasPrefix(base + "/") }.count
        }

        XCTAssertEqual(
            duplicated.count + nested, 0,
            "static overlaps can silently discard stricter safety metadata"
        )
    }

    /// The guarantee: after a scan, no path appears twice and no path lies
    /// inside another. Removing any item can therefore never invalidate a
    /// different one, and no byte is counted more than once.
    func testScanNeverReportsAPathTwiceOrNestedInsideAnother() throws {
        let scanner = CleanupScanner(includesProtectedLocations: false)
        let report = scanner.scan()

        var paths: [String] = []
        for group in report.groups {
            // The Trash is measured as a whole and removed with a different
            // disposal, so it is deliberately outside the dedup pass.
            guard group.category != .trash else { continue }
            for finding in group.findings {
                paths += finding.items.map { $0.url.standardizedFileURL.path }
            }
        }

        XCTAssertEqual(
            paths.count, Set(paths).count,
            "the same path was reported by more than one finding"
        )

        let sorted = paths.sorted()
        for (index, path) in sorted.enumerated() where index > 0 {
            let previous = sorted[index - 1]
            XCTAssertFalse(
                path.hasPrefix(previous + "/"),
                "\(path) is inside \(previous); removing the parent would strand the child"
            )
        }
    }

    /// The headline figure has to be the sum of what will actually be deleted.
    func testReportedBytesAreTheSumOfDistinctItems() {
        let scanner = CleanupScanner(includesProtectedLocations: false)
        let report = scanner.scan()

        for group in report.groups where group.category != .trash {
            let summed = group.findings.reduce(Int64(0)) { $0 + $1.bytes }
            XCTAssertEqual(group.bytes, summed)
        }
    }
}
