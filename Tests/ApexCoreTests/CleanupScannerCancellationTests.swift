import XCTest

@testable import ApexCore

final class CleanupScannerCancellationTests: XCTestCase {
    func testCancellationBeforeScanStartsIsNotCleared() {
        let scanner = CleanupScanner()
        scanner.cancel()
        var updates: [CleanupScanner.Progress] = []

        let report = scanner.scan(categories: [.userCaches]) { updates.append($0) }

        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(updates.isEmpty, "A pre-cancelled scan must not claim progress or completion")
    }
}
