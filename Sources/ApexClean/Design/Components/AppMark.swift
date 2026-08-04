import AppKit
import SwiftUI

extension Bundle {
    static let apexResources: Bundle = {
        if let url = Bundle.main.url(
            forResource: "ApexClean_ApexClean",
            withExtension: "bundle"
        ), let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}

enum CoastalAssets {
    static let appIcon = load("CoastalAtlasAppIcon")
    static let welcome = load("CoastalAtlasWelcome")

    private static func load(_ name: String) -> NSImage {
        guard
            let url = Bundle.apexResources.url(forResource: name, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            fatalError("Missing bundled image asset: \(name).png")
        }
        return image
    }
}

/// Generated Coastal Atlas identity mark.
struct AppMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: CoastalAssets.appIcon)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Shows the pointing-hand cursor on hover.
    ///
    /// SwiftUI buttons on macOS keep the arrow cursor, which makes custom
    /// controls feel inert. Tracking hover and pushing/popping the cursor is
    /// the reliable fix.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
