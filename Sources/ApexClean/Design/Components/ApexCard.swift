import SwiftUI

/// The standard surface: hairline border, a specular catch on the top edge, and
/// a soft shadow. Optional hover lift for anything interactive.
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
            .overlay(specularEdge)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.34 : 0.09),
                radius: hovering && interactive ? 22 : 14,
                x: 0,
                y: hovering && interactive ? 10 : 6
            )
            .scaleEffect(hovering && interactive && !reduceMotion ? 1.006 : 1)
            .animation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion), value: hovering)
            .onHover { hovering = $0 }
    }

    /// Opaque rather than material-backed.
    ///
    /// A translucent material over the drifting backdrop forces the compositor
    /// to recompute its blur on every frame, for every card on screen — the
    /// single most expensive thing this UI could do at idle. The card reads as a
    /// distinct surface through its fill, hairline and specular edge instead,
    /// which is also more legible over moving colour.
    private var surface: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.surface(scheme).opacity(scheme == .dark ? 0.94 : 0.97))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        (accent ?? Palette.hairline(scheme))
                            .opacity(accent != nil ? (hovering ? 0.55 : 0.30) : 1),
                        Palette.hairline(scheme).opacity(0.6),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }

    /// A one-pixel highlight along the top edge only. This is the detail that
    /// makes a flat rectangle read as a physical panel catching room light.
    private var specularEdge: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [Palette.specular(scheme), .clear],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 1
            )
            .blendMode(scheme == .dark ? .plusLighter : .normal)
            .allowsHitTesting(false)
    }
}

/// Rounded-square glyph tile used for category and module identity.
struct GlyphTile: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 34
    var filled: Bool = true

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
            .fill(
                filled
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [tint.opacity(0.30), tint.opacity(0.13)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
    }
}

/// Compact status pill.
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
                .fill(tint.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.chipRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// Section heading with an eyebrow and optional trailing accessory.
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
