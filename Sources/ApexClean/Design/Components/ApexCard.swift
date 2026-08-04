import SwiftUI

/// Flat outlined paper panel used across the Coastal Atlas interface.
struct ApexCard<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    var radius: CGFloat = Metrics.cardRadius
    var interactive: Bool = false
    var accent: Color? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
            .overlay(border)
            .overlay(alignment: .leading) {
                if let accent {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 3)
                        .padding(.vertical, 9)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(hovering && interactive && !reduceMotion ? 1.003 : 1)
            .animation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion), value: hovering)
            .onHover { hovering = $0 }
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                hovering && interactive
                    ? Palette.surfaceRaised(scheme)
                    : Palette.surface(scheme)
            )
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                accent?.opacity(hovering ? 0.9 : 0.65) ?? Palette.contour(scheme),
                lineWidth: 1.15
            )
    }
}

struct GlyphTile: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 34
    var filled: Bool = true

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(filled ? tint.opacity(scheme == .dark ? 0.20 : 0.16) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .strokeBorder(Palette.contour(scheme), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(scheme == .dark ? tint : Palette.charcoal)
            )
            .frame(width: size, height: size)
    }
}

struct Chip: View {
    let text: String
    var tint: Color
    var symbol: String? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(Typo.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Metrics.chipRadius, style: .continuous)
                .fill(tint.opacity(scheme == .dark ? 0.18 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.chipRadius, style: .continuous)
                .strokeBorder(Palette.contour(scheme), lineWidth: 0.8)
        )
        .fixedSize()
    }
}

struct SectionHeader<Accessory: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow).eyebrowStyle(scheme)
                Text(title)
                    .font(Typo.sectionTitle)
                    .foregroundStyle(Palette.ink(scheme))
                if let subtitle {
                    Text(subtitle)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}
