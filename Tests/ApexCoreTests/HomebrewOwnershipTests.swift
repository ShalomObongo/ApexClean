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

    func testMalformedMetadataIsNotTreatedAsReliableEmptyOwnership() {
        XCTAssertNil(HomebrewBridge.parseCaskAppOwnersResult(Data("{}".utf8)))
        XCTAssertEqual(
            HomebrewBridge.parseCaskAppOwnersResult(Data("{\"casks\":[]}".utf8)),
            [:]
        )
    }

    func testCustomLocationSiblingIsFoundAndSymlinkAliasIsDeduplicated() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let reviewed = try makeApp(
            at: parent.appendingPathComponent("Reviewed.app"),
            identifier: "com.example.product"
        )
        let sibling = try makeApp(
            at: parent.appendingPathComponent("Tools/Sibling.app"),
            identifier: "com.example.product.beta"
        )
        let alias = parent.appendingPathComponent("Sibling Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sibling)

        let paths = AppInventory.relatedApplicationPaths(
            for: "com.example.product",
            excluding: reviewed,
            candidates: [reviewed, sibling, alias]
        )

        XCTAssertEqual(paths, [sibling.resolvingSymlinksInPath()])
    }

    private func makeApp(at url: URL, identifier: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "CFBundleName": url.deletingPathExtension().lastPathComponent,
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
