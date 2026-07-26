import XCTest
@testable import ApexCore

/// PathGuard is the last line of defence before a deletion syscall, so these
/// tests are written adversarially: they assert what the guard *refuses*, not
/// what it permits.
final class PathGuardTests: XCTestCase {
    private var home: URL { PathGuard.home }

    // MARK: - Refusals

    func testRefusesVolumeRootAndSystemDirectories() {
        let forbidden = [
            "/", "/System", "/System/Library", "/Library", "/Users", "/Volumes",
            "/private", "/private/var", "/bin", "/sbin", "/usr", "/usr/local",
            "/opt", "/etc", "/dev", "/Applications", "/Users/Shared",
            "/Library/Caches", "/Library/LaunchDaemons", "/Library/Preferences",
        ]
        for path in forbidden {
            let verdict = PathGuard.evaluate(URL(fileURLWithPath: path))
            XCTAssertFalse(verdict.isAllowed, "Must refuse \(path), got \(verdict)")
        }
    }

    func testRefusesHomeAndItsTopLevelDirectories() {
        let leaves = [
            "", "/Library", "/Library/Caches", "/Library/Application Support",
            "/Library/Containers", "/Library/Preferences", "/Documents",
            "/Desktop", "/Downloads", "/Pictures", "/Movies", "/Music", "/.Trash",
            "/.ssh", "/.config", "/.cache",
        ]
        for leaf in leaves {
            let url = URL(fileURLWithPath: home.path + leaf)
            XCTAssertFalse(
                PathGuard.evaluate(url).isAllowed,
                "Must refuse \(url.path)"
            )
        }
    }

    func testRefusesIrreplaceablePersonalData() {
        let sacred = [
            "Documents/taxes/2024.pdf",
            "Desktop/notes.txt",
            "Pictures/Photos Library.photoslibrary",
            "Movies/wedding.mov",
            ".ssh/id_ed25519",
            ".gnupg/secring.gpg",
            "Library/Keychains/login.keychain-db",
            "Library/Mobile Documents/com~apple~CloudDocs/thesis.pages",
        ]
        for relative in sacred {
            let url = home.appendingPathComponent(relative)
            XCTAssertFalse(
                PathGuard.evaluate(url).isAllowed,
                "Must refuse personal data at \(relative)"
            )
        }
    }

    func testRefusesShallowPaths() {
        // Two components is always too coarse to be a legitimate cleanup target.
        XCTAssertFalse(PathGuard.evaluate(URL(fileURLWithPath: "/tmp/anything")).isAllowed)
        XCTAssertFalse(PathGuard.evaluate(URL(fileURLWithPath: "/Volumes/External")).isAllowed)
    }

    func testRefusesPathTraversalOutOfPermittedRoots() {
        // `standardizedFileURL` resolves the traversal, so this asserts the
        // outcome — escaping the permitted roots — not the literal syntax.
        let escaped = URL(fileURLWithPath: home.path + "/Library/Caches/../../../../etc/passwd")
        XCTAssertFalse(PathGuard.evaluate(escaped).isAllowed)
    }

    func testRefusesOutsidePermittedRoots() {
        for path in ["/usr/local/bin/tool", "/opt/homebrew/bin/brew", "/etc/hosts"] {
            XCTAssertFalse(
                PathGuard.evaluate(URL(fileURLWithPath: path)).isAllowed,
                "Must refuse \(path)"
            )
        }
    }

    func testRefusesSystemUISurfaces() {
        let protected = [
            "Library/Caches/com.apple.controlcenter/data",
            "Library/Containers/com.apple.Settings.Extension/Data",
            "Library/Caches/com.apple.finder/cache.db",
            "Library/Caches/com.apple.dock/icons",
        ]
        for relative in protected {
            XCTAssertFalse(
                PathGuard.evaluate(home.appendingPathComponent(relative)).isAllowed,
                "Must refuse system UI path \(relative)"
            )
        }
    }

    func testRefusesEndpointSecurityCaches() {
        let vendors = [
            "/private/var/folders/ab/xyz/C/com.crowdstrike.falcon.Agent",
            "/private/var/folders/ab/xyz/C/com.sentinelone.agent",
            "/var/folders/ab/xyz/T/com.jamf.management",
        ]
        for path in vendors {
            XCTAssertFalse(
                PathGuard.evaluate(URL(fileURLWithPath: path)).isAllowed,
                "Must refuse EDR scratch path \(path)"
            )
        }
    }

    // MARK: - Permissions

    func testAllowsRegenerableCaches() {
        let allowed = [
            "Library/Caches/com.example.app",
            "Library/Caches/com.example.app/Cache.db",
            "Library/Logs/ExampleApp/session.log",
            "Library/Developer/Xcode/DerivedData/Foo-abc123",
            "Library/Saved Application State/com.example.app.savedState",
        ]
        for relative in allowed {
            let verdict = PathGuard.evaluate(home.appendingPathComponent(relative))
            XCTAssertTrue(verdict.isAllowed, "Should allow \(relative), got \(verdict)")
        }
    }

    func testUserRootOverrideUnlocksPersonalFilesForSpaceLens() {
        let document = home.appendingPathComponent("Documents/big-video.mov")
        XCTAssertFalse(PathGuard.evaluate(document).isAllowed)
        // Space Lens acts only on an explicit selection, and only into the Trash.
        XCTAssertTrue(PathGuard.evaluate(document, allowUserRoots: true).isAllowed)
    }

    func testUserRootOverrideStillRefusesSystemPaths() {
        // The override widens which *user* data may be touched. It must never
        // become a way to reach system directories.
        for path in ["/", "/System", "/Library", "/usr/bin/swift"] {
            XCTAssertFalse(
                PathGuard.evaluate(URL(fileURLWithPath: path), allowUserRoots: true).isAllowed,
                "Override must not unlock \(path)"
            )
        }
    }

    // MARK: - Uninstall

    func testRefusesUninstallOfSystemCriticalBundles() {
        let critical = [
            "com.apple.finder", "com.apple.dock", "com.apple.Safari",
            "com.apple.systempreferences", "com.apple.controlcenter.helper",
            "com.apple.security.agent", "fit.apexclean.app",
        ]
        for bundleID in critical {
            let verdict = PathGuard.canUninstall(
                bundleID: bundleID,
                path: URL(fileURLWithPath: "/Applications/Thing.app")
            )
            XCTAssertFalse(verdict.isAllowed, "Must refuse uninstall of \(bundleID)")
        }
    }

    func testAllowsUninstallOfUserInstalledAppleApps() {
        // Xcode and Final Cut are Apple apps a user installed and may remove.
        for bundleID in ["com.apple.dt.Xcode", "com.apple.FinalCut"] {
            let verdict = PathGuard.canUninstall(
                bundleID: bundleID,
                path: URL(fileURLWithPath: "/Applications/Thing.app")
            )
            XCTAssertTrue(verdict.isAllowed, "Should allow uninstall of \(bundleID)")
        }
    }

    func testRefusesUninstallFromSealedSystemVolume() {
        let verdict = PathGuard.canUninstall(
            bundleID: "com.example.thing",
            path: URL(fileURLWithPath: "/System/Applications/Music.app")
        )
        XCTAssertFalse(verdict.isAllowed)
    }
}
