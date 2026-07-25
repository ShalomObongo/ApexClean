import XCTest

@testable import ApexCore

/// These assert the *contract*, not the grants.
///
/// A test process inherits the terminal's privacy permissions, so whether a
/// probe returns `granted` here says nothing about what the shipped app sees.
/// What can be tested is that every permission describes itself honestly, that
/// nothing claims to be requestable when macOS provides no request API, and
/// that a status check can never hang or prompt.
final class PermissionsTests: XCTestCase {
    func testEveryPermissionDescribesItself() {
        for permission in Permission.allCases {
            XCTAssertFalse(permission.title.isEmpty, "\(permission) has no title")
            XCTAssertFalse(permission.purpose.isEmpty, "\(permission) has no purpose")
            XCTAssertFalse(
                permission.consequence.isEmpty,
                "\(permission) does not say what happens without it"
            )
        }
    }

    /// macOS has no API to request Full Disk Access or App Management. Marking
    /// either as requestable would produce a button that appears to grant and
    /// silently does nothing.
    func testOnlyGenuinelyRequestablePermissionsAreMarkedSo() {
        XCTAssertFalse(Permission.fullDisk.isRequestable)
        XCTAssertFalse(Permission.appManagement.isRequestable)
        XCTAssertTrue(Permission.personalFolders.isRequestable)
        XCTAssertTrue(Permission.automation.isRequestable)
    }

    func testEveryPermissionHasASettingsDestination() {
        for permission in Permission.allCases {
            XCTAssertNotNil(permission.settingsURL, "\(permission) has nowhere to send the user")
        }
    }

    /// Distinct panes matter: sending someone to Full Disk Access when they need
    /// Automation is worse than sending them nowhere.
    func testSettingsDestinationsAreDistinct() {
        let urls = Permission.allCases.compactMap { $0.settingsURL?.absoluteString }
        XCTAssertEqual(Set(urls).count, Permission.allCases.count)
    }

    /// App Management cannot be detected, so it must report `unknown` rather
    /// than guessing at `denied` and nagging about something already granted.
    func testAppManagementReportsUnknownRatherThanGuessing() {
        XCTAssertEqual(Permissions.state(of: .appManagement), .unknown)
    }

    /// A status check runs on every launch and on every return to the app. If it
    /// could block, it would hang the window.
    func testStatusChecksReturnPromptly() {
        let started = Date()
        _ = Permissions.snapshot(allowingProbe: true)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 20,
            "a permission snapshot must never be the thing that stalls the app"
        )
    }

    /// Without a probe, personal folders must never be reported as `denied` —
    /// the honest answer before asking is "not determined". Reporting denial
    /// would make the UI claim a refusal the user never gave.
    func testPersonalFoldersAreNotDeclaredDeniedWithoutProbing() {
        let state = Permissions.state(of: .personalFolders, allowingProbe: false)
        XCTAssertTrue(
            state == .notDetermined || state == .granted,
            "expected notDetermined or granted (via Full Disk Access), got \(state)"
        )
    }

    func testOnlyFullDiskAccessRequiresARelaunch() {
        XCTAssertTrue(Permission.fullDisk.requiresRelaunch)
        for permission in Permission.allCases where permission != .fullDisk {
            XCTAssertFalse(permission.requiresRelaunch, "\(permission) should not need a relaunch")
        }
    }

    /// The app must remain usable with everything denied. If any permission were
    /// mandatory, refusing it would leave a broken app rather than a limited one.
    func testNoPermissionIsMandatory() {
        for permission in Permission.allCases {
            XCTAssertTrue(permission.isOptional, "\(permission) must not be required")
        }
    }

    func testPermissionsRoundTripThroughTheirRawValue() {
        for permission in Permission.allCases {
            XCTAssertEqual(Permission(rawValue: permission.rawValue), permission)
        }
    }
}
