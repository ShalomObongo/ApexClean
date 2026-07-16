import SwiftUI

/// Primary action. Gradient fill, specular top edge, and a press response that
/// is felt rather than seen.
struct ApexButton: View {
    enum Kind { case primary, secondary, quiet, destructive }

    let title: String
    var symbol: String? = nil
    var kind: Kind = .primary
    var size: Size = .regular
    var isLoading: Bool = false
    var action: () -> Void

    enum Size {
        case regular, large, compact

        var height: CGFloat {
            switch self {
            case .compact: 26
            case .regular: 32
            case .large: 44
            }
        }
        var font: Font {
            switch self {
            case .compact: .system(size: 11.5, weight: .semibold)
            case .regular: .system(size: 13, weight: .semibold)
            case .large: .system(size: 15, weight: .semibold)
            }
        }
        var horizontalPadding: CGFloat {
            switch self {
            case .compact: 11
            case .regular: 15
            case .large: 24
            }
        }
    }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: size == .large ? 13 : 11, weight: .bold))
                }
                Text(title).font(size.font)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(background)
            .overlay(stroke)
            .clipShape(Capsule(style: .continuous))
            .shadow(
                color: shadowColor,
                radius: hovering ? 14 : 8,
                x: 0,
                y: hovering ? 5 : 3
            )
            .scaleEffect(pressed && !reduceMotion ? 0.972 : 1)
            .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .animation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion), value: hovering)
        .animation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion), value: pressed)
        .onHover { hovering = $0 && isEnabled }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(hex: 0x04120C)
        case .secondary: Palette.ink(scheme)
        case .quiet: Palette.inkSecondary(scheme)
        case .destructive: Color.white
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            LinearGradient(
                colors: hovering
                    ? [Palette.jade.mixed(with: .white, amount: 0.12), Palette.cyan.mixed(with: .white, amount: 0.12)]
                    : [Palette.jade, Palette.cyan],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            Palette.surfaceRaised(scheme).opacity(hovering ? 1 : 0.8)
        case .quiet:
            Color.primary.opacity(hovering ? 0.07 : 0)
        case .destructive:
            LinearGradient(
                colors: hovering
                    ? [Palette.alert.mixed(with: .white, amount: 0.14), Palette.alert]
                    : [Palette.alert, Palette.alert.mixed(with: .black, amount: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch kind {
        case .primary, .destructive:
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        case .secondary:
            Capsule(style: .continuous).strokeBorder(Palette.hairline(scheme), lineWidth: 1)
        case .quiet:
            EmptyView()
        }
    }

    private var shadowColor: Color {
        switch kind {
        case .primary: Palette.jade.opacity(hovering ? 0.34 : 0.20)
        case .destructive: Palette.alert.opacity(hovering ? 0.32 : 0.18)
        default: .black.opacity(scheme == .dark ? 0.28 : 0.06)
        }
    }
}

/// Icon-only button for toolbars and row affordances.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var tint: Color? = nil
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? (hovering ? Palette.ink(scheme) : Palette.inkSecondary(scheme)))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(Motion.tactile, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Checkbox with a spring check-in. Used everywhere destructive selection happens.
struct ApexCheckbox: View {
    @Binding var isOn: Bool
    var tint: Color = Palette.jade
    var isMixed: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion)) {
                isOn.toggle()
            }
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn || isMixed ? tint : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            isOn || isMixed ? tint : Palette.inkTertiary(scheme).opacity(0.55),
                            lineWidth: 1.3
                        )
                )
                .overlay(
                    Group {
                        if isMixed {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Color(hex: 0x04120C))
                                .frame(width: 7, height: 2)
                        } else if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(Color(hex: 0x04120C))
                        }
                    }
                )
                .frame(width: 16, height: 16)
                .scaleEffect(isOn && !reduceMotion ? 1 : 0.98)
                // A 16pt box is the right size to look at and the wrong size to
                // hit — well under the ~28pt macOS expects, which made selecting
                // tasks and findings genuinely fiddly. Pad out to a comfortable
                // target, claim it for hit testing, then pad back in so the
                // surrounding layout is unchanged.
                .padding(6)
                .contentShape(Rectangle())
                .padding(-6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isMixed ? "Mixed" : (isOn ? "Selected" : "Not selected"))
    }
}
