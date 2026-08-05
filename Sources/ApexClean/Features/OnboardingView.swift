import ApexCore
import SwiftUI

/// First-run setup. Four steps: what this is, how it behaves, permissions, done.
///
/// The permissions step is the reason this exists. Handled badly, macOS privacy
/// dialogs arrive unannounced in the middle of a scan, with no explanation of
/// who is asking or why — which is precisely when people refuse them, and then
/// live with a half-working app forever. Asking once, up front, with the reason
/// stated and the consequence of declining stated just as plainly, is the whole
/// design.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            AtlasBackdrop(intensity: 0.7)

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity
                        )
                    )
                    .id(model.step)

                footer
            }
            .frame(maxWidth: 660)
            .padding(.vertical, 34)
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in
            // The user has most likely just come back from System Settings.
            model.refreshAfterReturn()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .howItWorks: howItWorks
        case .permissions: permissions
        case .ready: ready
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(nsImage: CoastalAssets.welcome)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 330, height: 190)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("ApexClean")
                    .font(Typo.display(38, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))

                Text("Mac care, transparently.")
                    .font(Typo.sectionTitle)
                    .foregroundStyle(Palette.info)
            }

            Text(
                "ApexClean finds space you can reclaim, removes applications completely, "
                    + "maps your disk and reports your Mac's condition — and shows you "
                    + "everything before it touches anything."
            )
            .font(Typo.body)
            .foregroundStyle(Palette.inkSecondary(scheme))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 470)

            if model.signatureChanged {
                ApexCard(padding: 13, accent: Palette.caution) {
                    HStack(alignment: .top, spacing: 10) {
                        GlyphTile(symbol: "arrow.triangle.2.circlepath", tint: Palette.caution, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("This is a new build")
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.ink(scheme))
                            Text(
                                "macOS ties privacy permissions to an app's signature, and this "
                                    + "build has a new one, so earlier grants no longer apply. "
                                    + "They need granting once more."
                            )
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 470)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            stepHeading(
                eyebrow: "How it behaves",
                title: "It looks before it acts",
                detail: "Three rules ApexClean does not break."
            )

            VStack(spacing: 12) {
                principle(
                    symbol: "eye",
                    tint: Palette.jade,
                    title: "Scanning is read-only",
                    detail: "Every scan only looks. Nothing is removed until you approve it, group by group."
                )
                principle(
                    symbol: "checkmark.shield",
                    tint: Palette.caution,
                    title: "Deletion is explicit",
                    detail:
                        "Cleanup and uninstall delete permanently, but only after you review the exact scope and confirm the irreversible action."
                )
                principle(
                    symbol: "lock.shield",
                    tint: Palette.sand,
                    title: "Nothing leaves your Mac",
                    detail: "There is no network code in this app. No telemetry, no account, no analytics."
                )
            }
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading(
                eyebrow: "Permissions",
                title: "Grant these once",
                detail: "ApexClean works without any of them — each one just removes a limitation. "
                    + "Nothing here is read unless you ask for it."
            )

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Permission.activeCases) { permission in
                        PermissionRow(
                            permission: permission,
                            state: model.state(of: permission),
                            isPending: model.pending == permission,
                            isLocked: model.pending != nil
                        ) {
                            model.grant(permission)
                        } onSettings: {
                            Permissions.openSettings(for: permission)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)

            if model.resumed {
                ApexCard(padding: 13, accent: Palette.jade) {
                    HStack(alignment: .center, spacing: 10) {
                        GlyphTile(symbol: "arrow.uturn.forward", tint: Palette.jade, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Picking up where you left off")
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.ink(scheme))
                            Text(
                                "macOS reopened ApexClean to apply a permission. Your earlier "
                                    + "answers were kept."
                            )
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        ApexButton(title: "Got it", kind: .quiet, size: .compact) {
                            model.acknowledgeResume()
                        }
                        .fixedSize()
                    }
                }
            }

            if model.relaunchRequired {
                ApexCard(padding: 13, accent: Palette.jade) {
                    HStack(alignment: .center, spacing: 10) {
                        GlyphTile(symbol: "checkmark.seal", tint: Palette.jade, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Full Disk Access granted")
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.ink(scheme))
                            Text(
                                "macOS applies this at launch, so ApexClean needs to reopen "
                                    + "before it can use it."
                            )
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        ApexButton(
                            title: "Reopen", symbol: "arrow.clockwise", kind: .secondary, size: .compact
                        ) {
                            model.relaunch()
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 34)
    }

    private var ready: some View {
        VStack(spacing: 18) {
            Spacer()
            GlyphTile(symbol: "checkmark", tint: Palette.jade, size: 64)

            VStack(spacing: 9) {
                Text("You're set up")
                    .font(Typo.display(30, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))

                Text(
                    model.grantedCount == 0
                        ? "No permissions granted — ApexClean will work within what macOS allows by default."
                        : "\(model.grantedCount) of \(Permission.activeCases.count) permissions granted. "
                            + "You can change any of them later from the ApexClean menu."
                )
                .font(Typo.body)
                .foregroundStyle(Palette.inkSecondary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            }

            Text("Start with a scan. It only looks.")
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
                .padding(.top, 2)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack(spacing: 12) {
            if !model.isFirstStep {
                ApexButton(title: "Back", kind: .quiet) { model.goBack() }
            }

            Spacer()

            StepDots(total: OnboardingModel.Step.allCases.count, current: model.step.rawValue)

            Spacer()

            if model.step == .permissions {
                ApexButton(title: "Grant what I can be asked for", kind: .secondary) {
                    model.grantAllRequestable()
                }
                .disabled(model.pending != nil)
            }

            ApexButton(
                title: model.isLastStep ? "Start using ApexClean" : "Continue",
                kind: .primary,
                size: model.isLastStep ? .large : .regular
            ) {
                model.advance()
            }
            .disabled(model.pending != nil)
        }
        .padding(.horizontal, 40)
        .padding(.top, 18)
        .overlay(alignment: .topLeading) {
            if !model.isLastStep {
                ApexButton(title: "Skip setup", kind: .quiet, size: .compact) { model.finish() }
                    .padding(.leading, 40)
                    .offset(y: -26)
                    .opacity(model.isFirstStep ? 1 : 0)
                    .allowsHitTesting(model.isFirstStep)
                    .accessibilityHidden(!model.isFirstStep)
            }
        }
    }

    private func stepHeading(eyebrow: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased())
                .font(Typo.eyebrow)
                .tracking(1.2)
                .foregroundStyle(Palette.inkTertiary(scheme))

            Text(title)
                .font(Typo.display(28, weight: .bold))
                .foregroundStyle(Palette.ink(scheme))

            Text(detail)
                .font(Typo.body)
                .foregroundStyle(Palette.inkSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func principle(
        symbol: String, tint: Color, title: String, detail: String
    ) -> some View {
        ApexCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                GlyphTile(symbol: symbol, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Typo.cardTitle)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(detail)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// One permission, its current state, and the only action macOS actually allows
/// for it — a request for some, a trip to System Settings for the rest.
private struct PermissionRow: View {
    let permission: Permission
    let state: PermissionState
    let isPending: Bool
    let isLocked: Bool
    var onGrant: () -> Void
    var onSettings: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ApexCard(padding: 14, accent: state.isGranted ? Palette.jade : nil) {
            HStack(alignment: .top, spacing: 12) {
                GlyphTile(symbol: symbol, tint: tint, size: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(permission.title)
                            .font(Typo.cardTitle)
                            .foregroundStyle(Palette.ink(scheme))

                        if state.isGranted {
                            Chip(text: "Granted", tint: Palette.jade, symbol: "checkmark")
                        } else if state == .denied {
                            Chip(text: "Not granted", tint: Palette.caution, symbol: "xmark")
                        }
                    }

                    Text(permission.purpose)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    if !state.isGranted {
                        Text(permission.consequence)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                            .fixedSize(horizontal: false, vertical: true)

                        if !permission.isRequestable {
                            // Saying so outright is better than a button that
                            // looks like it grants and silently does not.
                            Text("macOS only allows this to be turned on in System Settings.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.info)
                                .padding(.top, 1)
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(spacing: 6) {
                    if state.isGranted {
                        ApexButton(title: "Settings", kind: .quiet, size: .compact, action: onSettings)
                    } else {
                        ApexButton(
                            title: permission.isRequestable ? "Grant…" : "Open Settings",
                            symbol: permission.isRequestable ? "lock.open" : "arrow.up.forward.app",
                            kind: .secondary,
                            size: .compact,
                            isLoading: isPending,
                            action: onGrant
                        )
                        .disabled(isLocked)
                    }
                }
                .fixedSize()
            }
        }
    }

    private var symbol: String {
        if state.isGranted { return "lock.open" }
        switch permission {
        case .fullDisk: return "externaldrive"
        case .personalFolders: return "folder"
        case .automation: return "app.connected.to.app.below.fill"
        case .appManagement: return "square.and.arrow.down.on.square"
        }
    }

    private var tint: Color {
        state.isGranted ? Palette.jade : Palette.info
    }
}

private struct StepDots: View {
    let total: Int
    let current: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index == current ? Palette.jade : Palette.inkTertiary(scheme).opacity(0.35))
                    .frame(width: index == current ? 18 : 6, height: 6)
                    .animation(Motion.tactile, value: current)
            }
        }
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }
}
