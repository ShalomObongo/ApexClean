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

    func testRelatedBundleIdentifiersAreTreatedAsSharedOwnership() {
        XCTAssertTrue(
            LeftoverFinder.identifiersOverlap("com.vendor.app", "com.vendor.app.beta")
        )
        XCTAssertTrue(
            LeftoverFinder.identifiersOverlap("com.vendor.app.helper", "com.vendor.app")
        )
        XCTAssertFalse(
            LeftoverFinder.identifiersOverlap("com.vendor.app", "com.vendor.application")
        )
    }

    func testRejectsMalformedBundleIdentifiers() {
        // A bundle id containing glob metacharacters or separators must never
        // reach a `find -name` style pattern.
        for identifier in [
            "", "app", "com", "a.b", "com.example/*", "com.*", "../etc",
            "com..example", "com.example_", "com.-example.app", "com.example-.app",
        ] {
            XCTAssertFalse(
                LeftoverFinder.isReverseDNS(identifier),
                "\(identifier) must not be treated as a usable bundle id"
            )
        }
    }

    func testUninstallRefusesAnAppWithoutATrustworthyIdentifier() {
        let app = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Unidentified.app"),
            name: "Unidentified",
            bundleID: "",
            version: "",
            bundleBytes: 0,
            lastUsed: nil,
            installed: nil,
            isRunning: false,
            isSystem: false,
            source: .direct
        )
        let verdict = LeftoverFinder.uninstallVerdict(for: app)
        XCTAssertFalse(verdict.isAllowed)
        XCTAssertTrue(verdict.reason?.contains("bundle identifier") == true)
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
        // "Studio" is part of the product name, not a release channel, so the
        // bare first word must not be derived. This assertion used to be
        // inverted, which is how the shared-vendor sweep shipped.
        XCTAssertFalse(
            variants.contains("Maestro"),
            "a bare first word is a vendor or family name, not an app name"
        )
    }

    /// The bug this guards against: any multi-word name yielded its first word,
    /// so uninstalling one app offered to delete a directory its siblings share.
    func testVendorPrefixesAreNeverDerivedFromMultiWordNames() {
        let cases: [(app: String, forbidden: String)] = [
            ("Microsoft Word", "Microsoft"),
            ("Microsoft Excel", "Microsoft"),
            ("Adobe Acrobat Reader DC", "Adobe"),
            ("Google Chrome", "Google"),
            ("Affinity Photo 2", "Affinity"),
            ("Elgato Stream Deck", "Elgato"),
            ("Logitech Options Plus", "Logitech"),
        ]
        for (app, forbidden) in cases {
            let variants = Set(LeftoverFinder.nameVariants(app))
            XCTAssertFalse(
                variants.contains(forbidden),
                "\(app) must not claim the shared “\(forbidden)” directory"
            )
            XCTAssertTrue(variants.contains(app), "\(app) should still match its own name")
        }
    }

    /// Known release channels are still stripped, because those really are the
    /// same application writing to the same place.
    func testReleaseChannelSuffixesStillResolveToTheBaseName() {
        for (app, base) in [
            ("Zed Nightly", "Zed"),
            ("Visual Studio Code Insiders", "Visual Studio Code"),
            ("Firefox Developer Edition", "Firefox"),
            ("Chromium Canary", "Chromium"),
        ] {
            let variants = Set(LeftoverFinder.nameVariants(app))
            XCTAssertTrue(variants.contains(base), "\(app) should also cover “\(base)”")
        }
    }

    /// Only strong matches may arrive pre-ticked. A weak one is still listed —
    /// it is just the user's decision rather than the app's.
    func testOnlyStrongMatchesArePreselectable() {
        XCTAssertTrue(Leftover.Confidence.bundleIdentifier.isSafeToPreselect)
        XCTAssertFalse(Leftover.Confidence.exactName.isSafeToPreselect)
        XCTAssertFalse(Leftover.Confidence.derivedName.isSafeToPreselect)
    }

    func testAppControlledNamesCannotEscapeAPathComponent() {
        for name in [
            "", ".", "..", "../Library", "Thing/../../Documents", "Thing\\..\\Documents",
            "bad\0name",
        ] {
            XCTAssertFalse(
                LeftoverFinder.isSafePathComponent(name),
                "\(name.debugDescription) must not become a filesystem candidate"
            )
            XCTAssertTrue(LeftoverFinder.nameVariants(name).isEmpty)
        }
        XCTAssertTrue(LeftoverFinder.isSafePathComponent("Microsoft Word"))
        XCTAssertTrue(LeftoverFinder.isSafePathComponent("Zed Nightly"))
    }

    /// Confidence defaults to the cautious value, so a future call site that
    /// forgets to pass one cannot accidentally preselect.
    func testConfidenceDefaultsToTheCautiousValue() {
        let leftover = Leftover(
            url: URL(fileURLWithPath: "/tmp/example"),
            bytes: 0,
            kind: .support,
            evidence: "test"
        )
        XCTAssertEqual(leftover.confidence, .derivedName)
        XCTAssertFalse(leftover.confidence.isSafeToPreselect)
    }

    func testSingleWordNamesProduceNoSpuriousVariants() {
        XCTAssertEqual(Set(LeftoverFinder.nameVariants("Spotify")), ["Spotify"])
    }
}
