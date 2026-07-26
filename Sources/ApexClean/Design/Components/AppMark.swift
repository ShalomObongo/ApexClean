import SwiftUI

/// The ApexClean glyph — a rounded jade→cyan tile carrying a single spark.
///
/// One definition, used by the sidebar brand, the About panel, and anywhere
/// else the app needs to sign its name. Scales entirely off `size` so it stays
/// proportionally correct from 20pt to 96pt.
struct AppMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(Palette.accentGradient)

            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: size * 0.02)
                .blendMode(.plusLighter)

            Image(systemName: "sparkle")
                .font(.system(size: size * 0.46, weight: .black))
                .foregroundStyle(Color(hex: 0x04120C))
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.jade.opacity(0.45), radius: size * 0.32, y: size * 0.07)
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
