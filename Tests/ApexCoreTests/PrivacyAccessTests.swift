import XCTest
@testable import ApexCore

/// Guards the property that makes the app safe to run unattended: an automatic
/// scan must never read anything macOS gates behind a consent prompt, because a
/// pending prompt blocks the calling thread indefinitely.
final class PrivacyAccessTests: XCTestCase {
    private var home: String { PathGuard.home.path }

    func testDetectsProtectedUserFolders() {
        for path in [
            "\(home)/Downloads",
            "\(home)/Downloads/installer.dmg",
            "\(home)/Desktop/screenshot.png",
            "\(home)/Documents/report.pdf",
        ] {
            XCTAssertTrue(PrivacyAccess.isProtected(path), "\(path) should be protected")
            XCTAssertTrue(PrivacyAccess.requiresConsent(path))
        }
    }

    func testDetectsConsentGatedServices() {
        for path in [
            "\(home)/Library/Messages/StickerCache",
            "\(home)/Library/Mail/V10",
            "\(home)/Library/Safari/History.db",
            "\(home)/Library/Calendars/Calendar Cache",
            "\(home)/Library/Application Support/AddressBook/Sources",
            "\(home)/Library/Caches/com.apple.Safari/WebKitCache",
        ] {
            XCTAssertTrue(
                PrivacyAccess.requiresConsent(path),
                "\(path) needs consent and must be excluded from automatic scans"
            )
        }
    }

    func testOrdinaryCachesAreNotGated() {
        for path in [
            "\(home)/Library/Caches/com.spotify.client",
            "\(home)/Library/Logs/ExampleApp",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/.npm/_cacache",
        ] {
            XCTAssertFalse(
                PrivacyAccess.requiresConsent(path),
                "\(path) should be scannable without consent"
            )
        }
    }

    /// The load-bearing test: with `includesProtectedLocations` off, not a
    /// single rule in the catalog may point at consent-gated storage.
    func testAutomaticScanCatalogTouchesNothingGated() {
        let scanner = CleanupScanner(includesProtectedLocations: false)
        let offenders = CleanupCatalog.all
            .map(\.pattern)
            .filter { PrivacyAccess.requiresConsent($0.expandingTilde) }

        // Any offenders must be excluded by the scanner, so a scan with the flag
        // off completes without ever raising a dialog.
        let report = scanner.scan(
            categories: Set(CleanupCategory.allCases),
            running: RunningAppsSnapshot()
        )
        let scannedPaths = report.groups
            .flatMap(\.findings)
            .flatMap(\.items)
            .map(\.url.path)

        for path in scannedPaths {
            XCTAssertFalse(
                PrivacyAccess.requiresConsent(path),
                "Automatic scan reached consent-gated path \(path)"
            )
        }
        // Sanity: the catalog does contain such rules, so the filter is doing work.
        XCTAssertFalse(offenders.isEmpty, "Expected the catalog to contain gated rules to filter")
    }

    func testTildeExpansion() {
        XCTAssertEqual("~/Library/Caches".expandingTilde, "\(home)/Library/Caches")
        XCTAssertEqual("/absolute/path".expandingTilde, "/absolute/path")
    }

    /// Media libraries are gated by their own consent service, not Full Disk
    /// Access, and they live in folders that look completely ordinary. Reading
    /// `~/Music/Music` blocked a Space Lens scan in the kernel until a dialog
    /// that nobody was there to answer came back.
    func testMediaLibrariesAreTreatedAsGated() {
        let home = PathGuard.home.path
        let gated = [
            "\(home)/Music/Music",
            "\(home)/Music/Music/Media.localized/Music",
            "\(home)/Music/iTunes",
            "\(home)/Movies/TV",
            "\(home)/Pictures/Photos Library.photoslibrary",
        ]
        for path in gated {
            XCTAssertTrue(
                PrivacyAccess.requiresConsent(path),
                "\(path) can block a scan waiting on a consent dialog"
            )
        }
    }

    /// The gate is on the media library, not on the enclosing folder — people
    /// keep their own files in Music and Movies too.
    func testOrdinaryFilesBesideMediaLibrariesAreNotGated() {
        let home = PathGuard.home.path
        for path in ["\(home)/Music/demos", "\(home)/Movies/holiday.mp4", "\(home)/Pictures/screenshot.png"] {
            XCTAssertFalse(
                PrivacyAccess.requiresConsent(path),
                "\(path) is an ordinary user file and should still be measured"
            )
        }
    }

    /// Sandbox containers block rather than fail without Full Disk Access, and
    /// a Mac has hundreds of them. Walking into them turned a one-minute disk
    /// map into an hours-long crawl.
    func testSandboxContainersAreTreatedAsGated() {
        let home = PathGuard.home.path
        let gated = [
            "\(home)/Library/Containers",
            "\(home)/Library/Containers/com.apple.Safari",
            "\(home)/Library/Containers/com.example.Thing/Data/Library/Caches",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Group Containers/group.com.apple.storekit/Library",
        ]
        for path in gated {
            XCTAssertTrue(
                PrivacyAccess.requiresConsent(path),
                "\(path) blocks a scan instead of failing it"
            )
        }
    }
}
