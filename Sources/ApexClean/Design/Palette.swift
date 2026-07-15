import SwiftUI

/// The ApexClean palette.
///
/// Built around a jade→cyan signature rather than the pink/violet that
/// dominates this category, and anchored on a cool near-black canvas so the
/// accent reads as light rather than paint.
enum Palette {
    // MARK: - Canvas

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x080B0F) : Color(hex: 0xF4F3EF)
    }

    static func canvasDeep(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x05070A) : Color(hex: 0xEBE9E4)
    }

    /// Card fill. Deliberately close to the canvas — separation comes from the
    /// hairline and the shadow, not from a big tonal jump.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x11161D) : Color(hex: 0xFFFFFF)
    }

    static func surfaceRaised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x161C25) : Color(hex: 0xFFFFFF)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.08)
    }

    /// The 1px light catch along a card's top edge that sells physical depth.
    static func specular(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.9)
    }

    // MARK: - Ink

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF2F5F8) : Color(hex: 0x12161B)
    }

    static func inkSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x99A4B2) : Color(hex: 0x5C6773)
    }

    static func inkTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x5F6C7B) : Color(hex: 0x8B95A1)
    }

    // MARK: - Signature accent

    static let jade = Color(hex: 0x2FE0A0)
    static let cyan = Color(hex: 0x24CFE8)
    static let deepCyan = Color(hex: 0x1AA5D8)

    static let accentGradient = LinearGradient(
        colors: [jade, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accentGradientWide = LinearGradient(
        colors: [jade, cyan, deepCyan],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Semantics

    static let positive = Color(hex: 0x35D48A)
    static let caution = Color(hex: 0xF5B841)
    static let alert = Color(hex: 0xF2685C)
    static let info = Color(hex: 0x59A5F5)

    /// Status colour for a 0…100 health score.
    static func health(_ score: Int) -> Color {
        switch score {
        case 85...: positive
        case 65 ..< 85: jade
        case 45 ..< 65: caution
        default: alert
        }
    }

    /// Colour for a 0…1 utilisation ratio, where more is worse.
    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: jade
        case ..<0.8: Color(hex: 0x8BD44E)
        case ..<0.92: caution
        default: alert
        }
    }

    // MARK: - Category identity

    /// Each cleanup category gets a stable hue so a colour becomes learnable
    /// shorthand for a kind of finding.
    static func category(_ id: String) -> Color {
        switch id {
        case "userCaches": Color(hex: 0x2FE0A0)
        case "appLogs": Color(hex: 0x59A5F5)
        case "systemJunk": Color(hex: 0x8B7FF0)
        case "browserData": Color(hex: 0x24CFE8)
        case "developerJunk": Color(hex: 0xF5B841)
        case "aiTools": Color(hex: 0xE86FC4)
        case "leftovers": Color(hex: 0xFF8A5B)
        case "installers": Color(hex: 0x9BD44E)
        case "trash": Color(hex: 0xF2685C)
        default: Color(hex: 0x7A8798)
        }
    }

    static func categoryGradient(_ id: String) -> LinearGradient {
        let base = category(id)
        return LinearGradient(
            colors: [base, base.mixed(with: cyan, amount: 0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Blends toward another colour. Used to derive gradient partners from a
    /// single category hue so the palette stays coherent.
    func mixed(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = max(0, min(1, amount))
        return Color(
            .sRGB,
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t),
            opacity: Double(a.alphaComponent)
        )
    }
}
