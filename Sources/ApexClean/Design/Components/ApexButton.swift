import SwiftUI

/// Flat outlined action control.
struct ApexButton: View {
    enum Kind {
        case primary, secondary, quiet, destructive
    }

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
            case .compact: Typo.display(11.5, weight: .semibold)
            case .regular: Typo.display(13, weight: .semibold)
            case .large: Typo.display(15, weight: .semibold)
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: 11
            case .regular: 15
            case .large: 24
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact: 3
            case .regular: 5
            case .large: 8
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
                    Image(systemName: symbol)
                        .font(.system(size: size == .large ? 13 : 11, weight: .bold))
                }
                Text(title).font(size.font)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(minHeight: size.height)
            .background(background)
            .overlay(stroke)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(pressed && !reduceMotion ? 0.972 : 1)
            .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isLoading ? Text("Working") : Text(""))
        .accessibilityHint(isLoading ? Text("This action is still running") : Text(""))
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
        case .primary, .destructive: Color.white
        case .secondary: Palette.ink(scheme)
        case .quiet: Palette.inkSecondary(scheme)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            hovering ? Palette.action.mixed(with: .black, amount: 0.08) : Palette.action
        case .secondary:
            hovering ? Palette.seaSage.opacity(0.32) : Palette.seaSage.opacity(0.18)
        case .quiet:
            Palette.dustyBlue.opacity(hovering ? 0.14 : 0)
        case .destructive:
            hovering ? Palette.alertFill.mixed(with: .black, amount: 0.08) : Palette.alertFill
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch kind {
        case .primary:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.action.mixed(with: .black, amount: 0.22), lineWidth: 1)
        case .secondary:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.contour(scheme), lineWidth: 1)
        case .quiet:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hovering ? Palette.contour(scheme) : .clear, lineWidth: 1)
        case .destructive:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.alertFill.mixed(with: .black, amount: 0.22), lineWidth: 1)
        }
    }
}

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
                        .fill(Palette.dustyBlue.opacity(hovering ? 0.14 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hovering ? Palette.contour(scheme) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(Motion.tactile, value: hovering)
        .onHover { hovering = $0 }
    }
}

struct ApexCheckbox: View {
    @Binding var isOn: Bool
    var tint: Color = Palette.jade
    var isMixed: Bool = false
    var label: String = "Selection"

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion)) {
                isOn.toggle()
            }
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isOn || isMixed ? selectedFill : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isOn || isMixed ? Palette.contour(scheme) : Palette.inkTertiary(scheme),
                            lineWidth: 1.2
                        )
                )
                .overlay {
                    if isMixed {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(selectedMark)
                            .frame(width: 7, height: 2)
                    } else if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(selectedMark)
                    }
                }
                .frame(width: 16, height: 16)
                .scaleEffect(isOn && !reduceMotion ? 1 : 0.98)
                .padding(6)
                .contentShape(Rectangle())
                .padding(-6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isMixed ? "Mixed" : (isOn ? "Selected" : "Not selected"))
    }

    private var selectedFill: Color {
        scheme == .dark ? Palette.bone : Palette.charcoal
    }

    private var selectedMark: Color {
        scheme == .dark ? Palette.charcoal : Palette.bone
    }
}
