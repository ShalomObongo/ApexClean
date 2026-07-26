import SwiftUI
import ApexCore

struct ApplicationsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Injected by RootView and observed directly. A nested
    /// `ObservableObject` reached through `@EnvironmentObject` publishes
    /// nothing to this view, so the model must be observed here.
    @ObservedObject var model: ApplicationsModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 14)

            tabBar
                .padding(.horizontal, 28)
                .padding(.bottom, 14)

            Group {
                switch model.tab {
                case .installed: installedList
                case .updates: updatesList
                case .startup: startupList
                }
            }
        }
        .task { if model.apps.isEmpty { model.load() } }
        .sheet(item: Binding(
            get: { model.plan.map { PlanBox(plan: $0) } },
            set: { if $0 == nil { model.dismissPlan() } }
        )) { box in
            UninstallSheet(plan: box.plan, model: model)
        }
    }

    private var header: some View {
        PageHeader(
            eyebrow: "Applications",
            title: "Manage what's installed",
            subtitle: "\(model.apps.count) apps · \(Bytes.format(model.totalAppBytes)) in bundles. Uninstalling shows every file first."
        ) {
            HStack(spacing: 8) {
                searchField
                ApexButton(
                    title: model.isLoading ? "Scanning" : "Refresh",
                    symbol: "arrow.clockwise",
                    kind: .secondary,
                    isLoading: model.isLoading
                ) { model.load() }
                .disabled(model.isLoading)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkTertiary(scheme))
            TextField("Search", text: Binding(get: { model.search }, set: { model.search = $0 }))
                .textFieldStyle(.plain)
                .font(Typo.body)
                .frame(width: 130)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            Capsule().fill(Palette.surface(scheme).opacity(0.7))
        )
        .overlay(Capsule().strokeBorder(Palette.hairline(scheme), lineWidth: 1))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(ApplicationsModel.Tab.allCases) { tab in
                let selected = model.tab == tab
                Button {
                    withAnimation(Motion.tactile) { model.tab = tab }
                    if tab == .updates, model.outdated.isEmpty { model.checkUpdates() }
                } label: {
                    HStack(spacing: 6) {
                        Text(tab.rawValue).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        if tab == .updates, !model.outdated.isEmpty {
                            Text("\(model.outdated.count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Palette.jade.opacity(0.2)))
                                .foregroundStyle(Palette.jade)
                        }
                        if tab == .startup, !model.orphanedStartupItems.isEmpty {
                            Text("\(model.orphanedStartupItems.count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Palette.caution.opacity(0.2)))
                                .foregroundStyle(Palette.caution)
                        }
                    }
                    .foregroundStyle(selected ? Palette.ink(scheme) : Palette.inkSecondary(scheme))
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Palette.surfaceRaised(scheme).opacity(0.9) : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Palette.hairline(scheme) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if model.tab == .installed {
                Picker("", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    ForEach(ApplicationsModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 116)
            }
        }
    }

    // MARK: - Installed

    private var installedList: some View {
        Group {
            if model.apps.isEmpty {
                if model.isLoading {
                    StateView(kind: .working("Reading your Applications folders…"))
                } else {
                    StateView(
                        kind: .empty(
                            symbol: "square.grid.2x2",
                            title: "No applications found",
                            message: "ApexClean looks in /Applications, /Applications/Utilities, and your personal Applications folder."
                        ),
                        action: ("Try again", "arrow.clockwise", { model.load() })
                    )
                }
            } else if model.filteredApps.isEmpty {
                StateView(kind: .empty(
                    symbol: "magnifyingglass",
                    title: "No matches",
                    message: "Nothing installed matches “\(model.search)”."
                ))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if !model.unusedApps.isEmpty, model.search.isEmpty {
                            unusedBanner
                        }
                        ForEach(model.filteredApps) { app in
                            AppRow(app: app, isPreparing: model.isBuildingPlan && model.pendingUninstallID == app.id) { model.preparePlan(for: app) }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var unusedBanner: some View {
        let bytes = model.unusedApps.reduce(Int64(0)) { $0 + $1.bundleBytes }
        return ApexCard(padding: 14, accent: Palette.info) {
            HStack(spacing: 12) {
                GlyphTile(symbol: "clock.badge.questionmark", tint: Palette.info, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.unusedApps.count) apps unopened for 4 months")
                        .font(Typo.cardTitle)
                        .foregroundStyle(Palette.ink(scheme))
                    Text("\(Bytes.format(bytes)) in bundles. This is an observation, not a recommendation — you may still want them.")
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Updates

    private var updatesList: some View {
        ScrollView {
            VStack(spacing: 10) {
                if !HomebrewBridge.isAvailable {
                    ApexCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Update checking needs Homebrew")
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.ink(scheme))
                            Text("ApexClean does not run its own update service or contact vendor servers. Where Homebrew manages an app, ApexClean can surface and apply its updates. Apps from the App Store update through the App Store.")
                                .font(Typo.body)
                                .foregroundStyle(Palette.inkSecondary(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if model.isCheckingUpdates {
                    loadingCard("Checking Homebrew for updates…")
                } else if model.outdated.isEmpty {
                    ApexCard {
                        HStack(spacing: 12) {
                            GlyphTile(symbol: "checkmark.seal", tint: Palette.jade, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Everything Homebrew manages is current")
                                    .font(Typo.cardTitle)
                                    .foregroundStyle(Palette.ink(scheme))
                                Text("Checked \(model.outdated.isEmpty ? "just now" : "")")
                                    .font(Typo.secondary)
                                    .foregroundStyle(Palette.inkTertiary(scheme))
                            }
                            Spacer()
                            ApexButton(
                                title: model.isCheckingUpdates ? "Checking" : "Check again",
                                kind: .secondary,
                                size: .compact,
                                isLoading: model.isCheckingUpdates
                            ) {
                                model.checkUpdates()
                            }
                            .disabled(model.isCheckingUpdates)
                        }
                    }
                } else {
                    if model.outdated.count > 1 {
                        ApexCard(padding: 13, accent: Palette.jade) {
                            HStack(spacing: 12) {
                                GlyphTile(symbol: "square.and.arrow.down.on.square", tint: Palette.jade, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(model.outdated.count) updates available")
                                        .font(Typo.cardTitle)
                                        .foregroundStyle(Palette.ink(scheme))
                                    Text("Each one downloads a full application, so this can take a while.")
                                        .font(Typo.secondary)
                                        .foregroundStyle(Palette.inkTertiary(scheme))
                                }
                                Spacer()
                                ApexButton(
                                    title: model.upgrading.isEmpty
                                        ? "Update all"
                                        : "Updating \(model.upgrading.count)",
                                    kind: .primary,
                                    size: .compact,
                                    isLoading: !model.upgrading.isEmpty
                                ) {
                                    model.upgradeAll()
                                }
                                .disabled(!model.upgrading.isEmpty)
                            }
                        }
                    }

                    ForEach(model.outdated) { cask in
                        let isUpgrading = model.upgrading.contains(cask.token)
                        let failure = model.upgradeFailures[cask.token]
                        ApexCard(padding: 13, accent: failure != nil ? Palette.caution : nil) {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 12) {
                                    GlyphTile(
                                        symbol: failure != nil ? "exclamationmark.triangle" : "arrow.down.app",
                                        tint: failure != nil ? Palette.caution : Palette.jade,
                                        size: 30
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cask.token.replacingOccurrences(of: "-", with: " ").capitalized)
                                            .font(Typo.cardTitle)
                                            .foregroundStyle(Palette.ink(scheme))
                                        Text(isUpgrading
                                             ? "Downloading and installing \(cask.latestVersion)…"
                                             : "\(cask.currentVersion) → \(cask.latestVersion)")
                                            .font(Typo.numeric(11))
                                            .foregroundStyle(Palette.inkTertiary(scheme))
                                    }
                                    Spacer()
                                    ApexButton(
                                        title: isUpgrading ? "Updating" : (failure != nil ? "Try again" : "Update"),
                                        kind: .secondary,
                                        size: .compact,
                                        isLoading: isUpgrading
                                    ) {
                                        model.upgrade(cask)
                                    }
                                    .disabled(isUpgrading)
                                }

                                if let failure {
                                    Text(failure)
                                        .font(Typo.caption)
                                        .foregroundStyle(Palette.caution)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.leading, 42)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Startup

    private var startupList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !model.orphanedStartupItems.isEmpty {
                    ApexCard(padding: 14, accent: Palette.caution) {
                        HStack(spacing: 12) {
                            GlyphTile(symbol: "bolt.trianglebadge.exclamationmark", tint: Palette.caution, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(model.orphanedStartupItems.count) startup \(model.orphanedStartupItems.count == 1 ? "item points" : "items point") at a missing program")
                                    .font(Typo.cardTitle)
                                    .foregroundStyle(Palette.ink(scheme))
                                Text("launchd retries these on every login and they always fail. Safe to remove.")
                                    .font(Typo.secondary)
                                    .foregroundStyle(Palette.inkSecondary(scheme))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                ForEach(model.startupItems) { item in
                    StartupRow(item: item, isRemoving: model.removingStartupItems.contains(item.id)) { model.removeStartupItem(item) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private func loadingCard(_ text: String) -> some View {
        ApexCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(text).font(Typo.body).foregroundStyle(Palette.inkSecondary(scheme))
                Spacer()
            }
        }
    }
}

private struct PlanBox: Identifiable {
    var id: String { plan.app.id }
    let plan: UninstallPlan
}

private struct AppRow: View {
    let app: InstalledApp
    let isPreparing: Bool
    let onUninstall: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        ApexCard(padding: 12, interactive: true) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(Typo.cardTitle)
                            .foregroundStyle(Palette.ink(scheme))
                        if app.isRunning {
                            Chip(text: "Running", tint: Palette.jade, symbol: "circle.fill")
                        }
                    }
                    HStack(spacing: 6) {
                        Text(app.version).font(Typo.numeric(11))
                        Text("·")
                        Text(app.source.rawValue)
                        if let days = app.idleDays, days > 30 {
                            Text("·")
                            Text("opened \(days)d ago")
                        }
                    }
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                }

                Spacer(minLength: 8)

                if app.bundleBytes > 0 {
                    Text(Bytes.format(app.bundleBytes))
                        .font(Typo.numeric(12, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                } else {
                    // Sizes stream in after discovery; a settled placeholder
                    // avoids the list reflowing as each one arrives.
                    Text("—")
                        .font(Typo.numeric(12, weight: .semibold))
                        .foregroundStyle(Palette.inkTertiary(scheme).opacity(0.5))
                }

                ApexButton(
                    title: isPreparing ? "Reading" : "Uninstall…",
                    kind: .secondary,
                    size: .compact,
                    isLoading: isPreparing,
                    action: onUninstall
                )
                .disabled(isPreparing)
                .opacity(hovering || isPreparing ? 1 : 0.55)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct StartupRow: View {
    let item: StartupItem
    let isRemoving: Bool
    let onRemove: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        ApexCard(padding: 12, interactive: true, accent: item.isOrphaned ? Palette.caution : nil) {
            HStack(spacing: 12) {
                GlyphTile(
                    symbol: item.isOrphaned ? "bolt.slash" : "bolt",
                    tint: item.isOrphaned ? Palette.caution : (item.isApple ? Palette.inkTertiary(scheme) : Palette.info),
                    size: 30
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(Typo.cardTitle)
                            .foregroundStyle(Palette.ink(scheme))
                        if item.isOrphaned { Chip(text: "Broken", tint: Palette.caution) }
                        if item.isApple { Chip(text: "macOS", tint: Palette.inkTertiary(scheme)) }
                    }
                    Text(item.label)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(item.scope.rawValue)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                    Text(item.scope.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                }

                if item.scope == .userAgent, !item.isApple {
                    ApexButton(
                        title: isRemoving ? "Removing" : "Remove",
                        kind: .secondary,
                        size: .compact,
                        isLoading: isRemoving,
                        action: onRemove
                    )
                    .disabled(isRemoving)
                    .opacity(hovering || isRemoving ? 1 : 0.5)
                } else {
                    Text("Needs admin")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                        .frame(width: 68)
                }
            }
        }
        .onHover { hovering = $0 }
    }
}
