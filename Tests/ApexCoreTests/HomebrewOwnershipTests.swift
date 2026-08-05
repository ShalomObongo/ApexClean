import Foundation
import XCTest

@testable import ApexCore

final class HomebrewOwnershipTests: XCTestCase {
    func testParsesAppAndInstallerUninstallArtifacts() throws {
        let json = """
            {
              "casks": [
                {
                  "token": "ordinary",
                  "artifacts": [{"app": ["Ordinary.app"]}]
                },
                {
                  "token": "installer-cask",
                  "artifacts": [{"uninstall": [{"delete": ["/Applications/Installer App.app"]}]}]
                }
              ]
            }
            """
        let owners = HomebrewBridge.parseCaskAppOwners(Data(json.utf8))
        XCTAssertEqual(owners["/Applications/Ordinary.app"], "ordinary")
        XCTAssertEqual(owners["/Applications/Installer App.app"], "installer-cask")
    }
}
