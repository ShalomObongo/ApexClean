import SwiftUI

/// Typography scale.
///
/// Two jobs: an editorial display voice for headings and hero numbers, and a
/// strictly tabular voice for anything that changes while you watch it — a
/// jittering byte count reads as instability.
enum Typo {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Hero metrics. Rounded gives large numerals warmth; monospaced digits stop
    /// the layout from twitching as values update.
    static func metric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func numeric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    static let title = Font.system(size: 26, weight: .bold)
    static let sectionTitle = Font.system(size: 17, weight: .semibold)
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let secondary = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium)

    /// Small, wide-tracked, uppercase label used for section eyebrows.
    static let eyebrow = Font.system(size: 10, weight: .bold)
}

extension View {
    /// Applies the eyebrow treatment: uppercase, tracked, tertiary ink.
    func eyebrowStyle(_ scheme: ColorScheme) -> some View {
        font(Typo.eyebrow)
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(Palette.inkTertiary(scheme))
    }
}

/// Motion vocabulary. A small set of named curves keeps timing consistent, and
/// each one honours Reduce Motion by collapsing to a near-instant crossfade.
enum Motion {
    /// Content arriving or leaving.
    static let enter = Animation.spring(response: 0.48, dampingFraction: 0.82)
    /// Direct manipulation feedback — hover, press, selection.
    static let tactile = Animation.spring(response: 0.28, dampingFraction: 0.72)
    /// Large state changes, e.g. idle → scanning → results.
    static let stage = Animation.spring(response: 0.66, dampingFraction: 0.86)
    /// Continuously updating values (graphs, counters).
    static let stream = Animation.easeOut(duration: 0.45)
    /// A single celebratory overshoot. Used sparingly, once per completion.
    static let settle = Animation.spring(response: 0.55, dampingFraction: 0.6)

    static func respectingReduceMotion(_ animation: Animation, _ reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.12) : animation
    }

    /// Staggered delay for list reveals, capped so long lists do not crawl in.
    static func stagger(_ index: Int, step: Double = 0.035, cap: Double = 0.32) -> Double {
        min(Double(index) * step, cap)
    }
}

/// Shared geometry so corner radii and insets stay in a family.
enum Metrics {
    static let cardRadius: CGFloat = 16
    static let tileRadius: CGFloat = 12
    static let chipRadius: CGFloat = 8
    static let cardPadding: CGFloat = 18
    static let gutter: CGFloat = 16
    static let sidebarWidth: CGFloat = 232
}
