import SwiftUI
import ApexCore

/// Offers to widen a scan into the folders macOS protects.
///
/// The whole point of this control is that consent is *requested*, in context,
/// with the reason stated — rather than a system dialog appearing out of nowhere
/// mid-scan. Nothing here reads a protected folder until the button is pressed.
struct PrivacyInviteCard: View {
    let title: String
    let detail: String
    let scopes: [PrivacyAccess.Scope]
    @Binding var isEnabled: Bool
    var onEnable: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var checking = false

    var body: some View {
        ApexCard(padding: 15, accent: isEnabled ? Palette.jade : Palette.info) {
            HStack(alignment: .top, spacing: 12) {
                GlyphTile(
                    symbol: isEnabled ? "lock.open" : "lock",
                    tint: isEnabled ? Palette.jade : Palette.info,
                    size: 32
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(Typo.cardTitle)
                        .foregroundStyle(Palette.ink(scheme))

                    Text(detail)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    if !isEnabled {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(scopes) { scope in
                                HStack(spacing: 6) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 3))
                                        .foregroundStyle(Palette.inkTertiary(scheme))
                                    Text("**\(scope.title)** — \(scope.purpose)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.inkTertiary(scheme))
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                VStack(spacing: 6) {
                    if isEnabled {
                        Chip(text: "Included", tint: Palette.jade, symbol: "checkmark")
                        ApexButton(title: "Exclude", kind: .quiet, size: .compact) {
                            isEnabled = false
                        }
                    } else {
                        ApexButton(
                            title: "Include…",
                            symbol: "lock.open",
                            kind: .secondary,
                            size: .compact,
                            isLoading: checking
                        ) {
                            grant()
                        }
                        ApexButton(title: "Settings", kind: .quiet, size: .compact) {
                            PrivacyAccess.openPrivacySettings()
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    private func grant() {
        checking = true
        // The read happens here, on an explicit press, which is the only moment
        // a consent dialog is an expected part of the interaction.
        Task {
            let granted = await Task.detached(priority: .userInitiated) {
                scopes.allSatisfy { PrivacyAccess.isReadable($0) }
            }.value

            await MainActor.run {
                checking = false
                withAnimation(Motion.enter) { isEnabled = granted }
                if !granted { PrivacyAccess.openPrivacySettings() }
                if granted { onEnable() }
            }
        }
    }
}
