import ApexCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            AtlasBackdrop(
                intensity: state.destination == .smartCare ? 1.0 : 0.55,
                energy: state.cleanup.stage == .scanning ? 1 : 0
            )

            HStack(spacing: 0) {
                Sidebar()
                Divider().overlay(Palette.contour(scheme))
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityHidden(state.isOnboarding)

            // Covers the app entirely rather than sitting in a sheet: setup is
            // the task until it is finished, and a half-visible app behind it
            // would only invite people to dismiss it and hit the dialogs later.
            if state.isOnboarding {
                OnboardingView(model: state.onboarding)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(minWidth: 1_040, minHeight: 700)
        .preferredColorScheme(nil)
        .onAppear { state.vitals.addSubscriber() }
        .onDisappear { state.vitals.removeSubscriber() }
        // Visibility, not activity: a window the user is watching while working
        // in another app should stay live, but one that is minimised, hidden,
        // or fully covered should not be paying for charts nobody can see.
        // Occlusion alone is not enough — hiding or minimising an app does not
        // reliably post it — so every event that can take the window off screen
        // is funnelled through the same recomputation.
        .onReceive(WindowVisibility.changes) { _ in
            state.vitals.setLiveUpdates(WindowVisibility.isAnyWindowOnScreen)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch state.destination {
            case .smartCare: SmartCareView(model: state.cleanup)
            case .cleanup: CleanupView(model: state.cleanup)
            case .applications: ApplicationsView(model: state.applications)
            case .maintenance: MaintenanceView(model: state.maintenance)
            case .spaceLens: SpaceLensView(model: state.space)
            case .vitals: VitalsView(monitor: state.vitals)
            case .history: HistoryView()
            }
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity
            )
        )
        .id(state.destination)
    }
}

struct Sidebar: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.top, 26)
                .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(Destination.allCases) { destination in
                    SidebarRow(
                        destination: destination,
                        isSelected: state.destination == destination,
                        badge: badge(for: destination)
                    ) {
                        state.go(to: destination)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            SidebarHealthFooter(vitals: state.vitals) { state.go(to: .vitals) }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .frame(width: Metrics.sidebarWidth)
        .background(Palette.sidebar(scheme))
    }

    private var brand: some View {
        HStack(spacing: 10) {
            AppMark(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("ApexClean")
                    .font(Typo.display(15, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))
                Text("Storage, clearly mapped")
                    .font(Typo.display(10, weight: .medium))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
    }

    private func badge(for destination: Destination) -> String? {
        switch destination {
        case .cleanup:
            let bytes = state.cleanup.report.totalBytes
            return bytes > 0 ? Bytes.format(bytes) : nil
        case .applications:
            let count = state.applications.outdated.count
            return count > 0 ? "\(count)" : nil
        default:
            return nil
        }
    }
}

private struct SidebarRow: View {
    let destination: Destination
    let isSelected: Bool
    var badge: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(indexLabel)
                    .font(Typo.numeric(9, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? Palette.ink(scheme) : Palette.inkSecondary(scheme)
                    )
                    .frame(width: 18, alignment: .leading)

                Image(systemName: destination.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.ink(scheme) : Palette.inkSecondary(scheme))
                    .frame(width: 20)

                Text(destination.title)
                    .font(Typo.display(13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.ink(scheme) : Palette.inkSecondary(scheme))

                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.ink(scheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(destination.tint.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Palette.contour(scheme), lineWidth: 0.8)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? Palette.seaSage.opacity(scheme == .dark ? 0.24 : 0.34)
                            : Palette.dustyBlue.opacity(hovering ? 0.10 : 0)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? Palette.contour(scheme) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion), value: isSelected)
        .animation(Motion.respectingReduceMotion(Motion.tactile, reduceMotion), value: hovering)
        .onHover { hovering = $0 }
        .help(destination.subtitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var indexLabel: String {
        guard let index = Destination.allCases.firstIndex(of: destination) else { return "—" }
        return String(format: "%02d", index + 1)
    }
}

/// Shared page chrome: a title block plus optional trailing controls.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.brick)
                    .frame(width: 4, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(eyebrow).eyebrowStyle(scheme)
                    Text(title)
                        .font(Typo.title)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(subtitle)
                        .font(Typo.body)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A compact, non-alarming condition readout. It never turns red to sell a
/// cleanup; it reports what the evaluator actually measured.
///
/// Its own view so it can observe `VitalsMonitor` directly — reaching the
/// monitor through `AppState` would subscribe to the wrong publisher and the
/// readout would silently freeze.
private struct SidebarHealthFooter: View {
    @ObservedObject var vitals: VitalsMonitor
    var onTap: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let health = vitals.snapshot.health
        let storage = vitals.snapshot.storage

        return Button(action: onTap) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    ZStack {
                        RingGauge(
                            value: Double(health.value) / 100,
                            tint: Palette.health(health.value),
                            thickness: 3.5
                        )
                        .frame(width: 32, height: 32)
                        Text("\(health.value)")
                            .font(Typo.metric(12, weight: .bold))
                            .foregroundStyle(Palette.ink(scheme))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("System health")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                        Text(health.band.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.health(health.value))
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 5) {
                    CapacityBar(
                        used: storage.used,
                        total: storage.total,
                        height: 5,
                        tint: Palette.load(storage.usedFraction)
                    )
                    Text("\(Bytes.format(storage.free)) free of \(Bytes.format(storage.total))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.surface(scheme).opacity(scheme == .dark ? 0.5 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.hairline(scheme), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the Vitals screen")
    }
}
