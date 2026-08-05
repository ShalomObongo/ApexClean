import SwiftUI

/// Coastal Atlas palette: warm paper, restrained coastal colour and one brick action.
enum Palette {
    static let bone = Color(hex: 0xE7E2D6)
    static let seaSage = Color(hex: 0xA9C3C0)
    static let sand = Color(hex: 0xD9BFA4)
    static let dustyBlue = Color(hex: 0x7E9AA6)
    static let brick = Color(hex: 0xC24E3C)
    static let charcoal = Color(hex: 0x26384A)

    // MARK: - Canvas

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x172126) : bone
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x202B31) : Color(hex: 0xF7F3EA)
    }

    static func surfaceRaised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x28343A) : Color(hex: 0xEEE9DE)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x141D22) : Color(hex: 0xEFEADF)
    }

    static func contour(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? seaSage.opacity(0.48) : charcoal.opacity(0.72)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        contour(scheme).opacity(scheme == .dark ? 0.48 : 0.30)
    }

    // MARK: - Ink

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF2EDE1) : Color(hex: 0x24313D)
    }

    static func inkSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xBBC4C6) : Color(hex: 0x566570)
    }

    static func inkTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xA2AEB1) : Color(hex: 0x566570)
    }

    // MARK: - Compatibility accents

    static let jade = Color.adaptive(light: 0x426E5A, dark: 0x9BC7B0)
    static let cyan = Color.adaptive(light: 0x3F6271, dark: 0x9BBAC5)
    static let action = brick

    // MARK: - Semantics

    static let positive = jade
    static let caution = Color.adaptive(light: 0x81501E, dark: 0xE2AE6B)
    static let alert = Color.adaptive(light: 0x8F3832, dark: 0xF27A70)
    static let alertFill = Color(hex: 0xA9443A)
    static let info = cyan

    static func health(_ score: Int) -> Color {
        switch score {
        case 85...: positive
        case 65..<85: jade
        case 45..<65: caution
        default: alert
        }
    }

    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: jade
        case ..<0.8: cyan
        case ..<0.92: caution
        default: alert
        }
    }

    // MARK: - Category identity

    static func category(_ id: String) -> Color {
        switch id {
        case "userCaches": jade
        case "appLogs": cyan
        case "systemJunk": Color.adaptive(light: 0x6D5878, dark: 0xC2AEC9)
        case "browserData": Color.adaptive(light: 0x3F7772, dark: 0x9CCBC6)
        case "developerJunk": Color.adaptive(light: 0x7D5A27, dark: 0xE0B475)
        case "aiTools": Color.adaptive(light: 0x765266, dark: 0xD4A9BD)
        case "leftovers": Color.adaptive(light: 0x9A3D36, dark: 0xF07A6F)
        case "installers": Color.adaptive(light: 0x567044, dark: 0xB6CC9D)
        case "trash": Color.adaptive(light: 0x87332F, dark: 0xF27A70)
        default: Color.adaptive(light: 0x53636D, dark: 0xB2BEC3)
        }
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

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                let value = match == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            })
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
