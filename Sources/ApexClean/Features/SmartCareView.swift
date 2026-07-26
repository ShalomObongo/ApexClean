import SwiftUI
import ApexCore

/// The signature screen: scan, then group, explain, and approve.
///
/// Nothing here removes anything on its own. The primary button changes meaning
/// between stages, and the destructive one is never the default action until a
/// review has actually happened.
struct SmartCareView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Injected by RootView and observed directly. A nested
    /// `ObservableObject` reached through `@EnvironmentObject` publishes
    /// nothing to this view, so the model must be observed here.
    @ObservedObject var model: CleanupModel

    @State private var isConfirming = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                hero
                if model.stage == .reviewing || model.stage == .cleaning {
                    groupSummary
                }
                if model.stage == .finished, let outcome = model.lastOutcome {
                    completionCard(outcome)
                }
                if !model.blockedFindings.isEmpty, model.stage == .reviewing {
                    blockedNotice
                }
                if !model.report.stalledRules.isEmpty {
                    stalledNotice
                }
                privacyInvite
                assurance
            }
            .padding(28)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $isConfirming) {
            RemovalConfirmation(model: model) { model.clean() }
        }
    }

    // MARK: - Header

    private var header: some View {
        PageHeader(
            eyebrow: "Smart Care",
            title: greeting,
            subtitle: "ApexClean looks first, then shows you everything it found. Nothing is removed until you approve it."
        ) {
            if state.totalReclaimedEver > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Reclaimed to date").eyebrowStyle(scheme)
                    Text(Bytes.format(state.totalReclaimedEver))
                        .font(Typo.metric(19, weight: .bold))
                        .foregroundStyle(Palette.accentGradient)
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5 ..< 12: return "Good morning"
        case 12 ..< 18: return "Good afternoon"
        case 18 ..< 23: return "Good evening"
        default: return "Still up?"
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ApexCard(padding: 30) {
            VStack(spacing: 22) {
                ReclaimDial(
                    phase: dialPhase,
                    segments: model.dialSegments,
                    totalBytes: heroBytes,
                    highlighted: model.focusedCategory
                )
                .padding(.top, 6)

                if model.stage == .scanning {
                    scanProgressStrip
                }

                actions

                if model.stage == .reviewing {
                    selectionSummary
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var dialPhase: ReclaimDial.Phase {
        switch model.stage {
        case .idle: .idle
        case .scanning:
            .scanning(progress: model.progress.fraction, label: model.progress.currentTitle)
        case .reviewing, .cleaning: .results
        case .finished: model.report.isEmpty ? .clean : .results
        }
    }

    private var heroBytes: Int64 {
        model.stage == .scanning ? model.progress.bytesFound : model.report.totalBytes
    }

    private var scanProgressStrip: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline(scheme))
                    Capsule()
                        .fill(Palette.accentGradientWide)
                        .frame(width: geometry.size.width * model.progress.fraction)
                        .animation(Motion.stream, value: model.progress.fraction)
                }
            }
            .frame(height: 4)

            HStack {
                Text("\(model.progress.completed) of \(model.progress.total) checks")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                Spacer()
                Text("Read-only — nothing is being changed")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var actions: some View {
        switch model.stage {
        case .idle:
            ApexButton(title: "Scan my Mac", symbol: "sparkles", kind: .primary, size: .large) {
                model.scan()
            }
        case .scanning:
            ApexButton(title: "Stop", symbol: "stop.fill", kind: .secondary, size: .large) {
                model.cancelScan()
            }
        case .reviewing:
            HStack(spacing: 10) {
                ApexButton(
                    title: "Remove \(Bytes.format(model.selectedBytes))",
                    symbol: "trash",
                    kind: .primary,
                    size: .large
                ) {
                    isConfirming = true
                }
                .disabled(model.selectedBytes == 0)

                ApexButton(title: "Review in detail", symbol: "list.bullet", kind: .secondary, size: .large) {
                    state.go(to: .cleanup)
                }
            }
        case .cleaning:
            ApexButton(title: "Removing…", kind: .primary, size: .large, isLoading: true) {}
                .disabled(true)
        case .finished:
            HStack(spacing: 10) {
                ApexButton(title: "Scan again", symbol: "arrow.clockwise", kind: .secondary, size: .large) {
                    model.scan()
                }
                if !model.report.isEmpty {
                    ApexButton(title: "Review what's left", kind: .quiet, size: .large) {
                        model.reset()
                        state.go(to: .cleanup)
                    }
                }
            }
        }
    }

    private var selectionSummary: some View {
        HStack(spacing: 14) {
            Label {
                Text("\(model.selectedFindings.count) of \(model.report.groups.flatMap(\.findings).count) groups approved")
                    .font(Typo.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
            }
            .foregroundStyle(Palette.inkSecondary(scheme))

            Divider().frame(height: 12)

            Label {
                Text("Recoverable from Trash")
                    .font(Typo.secondary)
            } icon: {
                Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 11))
            }
            .foregroundStyle(Palette.inkSecondary(scheme))
        }
    }

    // MARK: - Groups

    private var groupSummary: some View {
        VStack(spacing: 10) {
            SectionHeader(
                eyebrow: "Findings",
                title: "What ApexClean found",
                subtitle: "Approve each group individually. Hover a row to see it on the dial."
            ) {
                HStack(spacing: 6) {
                    ApexButton(title: "Recommended", kind: .quiet, size: .compact) {
                        model.selectRecommended()
                    }
                    ApexButton(title: "All", kind: .quiet, size: .compact) { model.selectAll() }
                    ApexButton(title: "None", kind: .quiet, size: .compact) { model.selectNone() }
                }
            }
            .padding(.horizontal, 2)

            ForEach(Array(model.report.groups.enumerated()), id: \.element.id) { index, group in
                GroupSummaryRow(group: group, model: model)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .animation(
                        Motion.respectingReduceMotion(
                            Motion.enter.delay(Motion.stagger(index)),
                            reduceMotion
                        ),
                        value: model.report.groups.count
                    )
            }
        }
    }

    private var blockedNotice: some View {
        ApexCard(padding: 15, accent: Palette.caution) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.caution)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some items were skipped")
                        .font(Typo.cardTitle)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(blockedMessage)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var blockedMessage: String {
        let apps = Set(model.blockedFindings.flatMap(\.blockedBy)).sorted()
        let list = ListFormatter.localizedString(byJoining: apps)
        let bytes = Bytes.format(model.blockedFindings.reduce(0) { $0 + $1.bytes })
        return "\(bytes) belongs to \(list), which \(apps.count == 1 ? "is" : "are") running. "
            + "Removing cache files out from under a live app can corrupt its state, so these are held back. Quit and scan again to include them."
    }

    // MARK: - Completion

    private func completionCard(_ outcome: Remover.Outcome) -> some View {
        ApexCard(padding: 22, accent: Palette.jade) {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Palette.jade.opacity(0.14))
                            .frame(width: 46, height: 46)
                        Image(systemName: "checkmark")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Palette.accentGradient)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reclaimed \(Bytes.format(outcome.bytesReclaimed))")
                            .font(Typo.metric(21, weight: .bold))
                            .foregroundStyle(Palette.ink(scheme))
                        Text(completionDetail(outcome))
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                    }
                    Spacer(minLength: 0)
                }

                if !outcome.refused.isEmpty || !outcome.failed.isEmpty {
                    Divider().overlay(Palette.hairline(scheme))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(outcome.refused.prefix(3).enumerated()), id: \.offset) { _, entry in
                            detailLine(
                                symbol: "shield.lefthalf.filled",
                                tint: Palette.info,
                                title: Glob.display(entry.url.path),
                                detail: entry.reason
                            )
                        }
                        ForEach(Array(outcome.failed.prefix(3).enumerated()), id: \.offset) { _, entry in
                            detailLine(
                                symbol: "exclamationmark.triangle",
                                tint: Palette.caution,
                                title: Glob.display(entry.url.path),
                                detail: entry.error
                            )
                        }
                    }
                }
            }
        }
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    private func completionDetail(_ outcome: Remover.Outcome) -> String {
        var parts: [String] = ["\(Count.files(outcome.filesRemoved)) removed"]
        if outcome.trashed > 0 {
            parts.append("\(outcome.trashed) recoverable from Trash")
        }
        if !outcome.refused.isEmpty {
            parts.append("\(outcome.refused.count) refused by safety checks")
        }
        return parts.joined(separator: " · ")
    }

    private func detailLine(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint)
            Text(title)
                .font(Typo.caption)
                .foregroundStyle(Palette.inkSecondary(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
            Spacer(minLength: 0)
        }
    }

    // MARK: - Privacy

    private var stalledNotice: some View {
        ApexCard(padding: 15, accent: Palette.info) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.info)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.report.stalledRules.count) \(model.report.stalledRules.count == 1 ? "location" : "locations") stopped responding")
                        .font(Typo.cardTitle)
                        .foregroundStyle(Palette.ink(scheme))
                    Text("ApexClean moved on rather than waiting. This usually means macOS wants explicit permission for that folder, or it lives on a disconnected drive. Skipped: \(model.report.stalledRules.prefix(4).joined(separator: ", "))\(model.report.stalledRules.count > 4 ? "…" : "").")
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var privacyInvite: some View {
        PrivacyInviteCard(
            title: "Downloads and Desktop are not scanned",
            detail: "macOS protects these folders, so ApexClean leaves them alone unless you say otherwise. Nothing there is read until you include them.",
            scopes: [.downloads, .desktop],
            isEnabled: Binding(
                get: { model.includesProtectedLocations },
                set: { model.includesProtectedLocations = $0 }
            ),
            onEnable: { model.scan() }
        )
    }

    // MARK: - Assurance

    private var assurance: some View {
        HStack(spacing: 0) {
            assuranceItem(
                symbol: "eye",
                title: "Scan first",
                detail: "Every pass is read-only until you approve."
            )
            Divider().frame(height: 30).overlay(Palette.hairline(scheme))
            assuranceItem(
                symbol: "arrow.uturn.backward",
                title: "Recoverable",
                detail: "Removals go to the Trash wherever possible."
            )
            Divider().frame(height: 30).overlay(Palette.hairline(scheme))
            assuranceItem(
                symbol: "shield.lefthalf.filled",
                title: "Fails closed",
                detail: "Anything ambiguous is refused, not guessed."
            )
        }
        .padding(.vertical, 4)
        .opacity(0.9)
    }

    private func assuranceItem(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.jade)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.ink(scheme))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One approvable group. Collapsed by default; expanding reveals the individual
/// findings with their evidence.
private struct GroupSummaryRow: View {
    let group: CleanupGroup
    @ObservedObject var model: CleanupModel

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var isExpanded: Bool { model.expandedGroups.contains(group.id) }

    var body: some View {
        let state = model.selectionState(for: group)
        let tint = Palette.category(group.category.rawValue)

        ApexCard(padding: 14, interactive: true, accent: hovering ? tint : nil) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ApexCheckbox(
                        isOn: Binding(
                            get: { state.isOn },
                            set: { _ in model.toggle(group: group) }
                        ),
                        tint: tint,
                        isMixed: state.isMixed
                    )

                    GlyphTile(symbol: group.category.symbol, tint: tint, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(group.category.title)
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.ink(scheme))
                            if group.highestRisk == .noticeable {
                                Chip(text: "Review carefully", tint: Palette.caution)
                            }
                        }
                        Text(group.category.subtitle)
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkTertiary(scheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Bytes.format(group.bytes))
                            .font(Typo.metric(15, weight: .semibold))
                            .foregroundStyle(Palette.ink(scheme))
                        Text("\(group.findings.count) \(group.findings.count == 1 ? "item" : "items")")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.inkTertiary(scheme))
                    }

                    Button {
                        withAnimation(Motion.enter) {
                            if isExpanded { model.expandedGroups.remove(group.id) }
                            else { model.expandedGroups.insert(group.id) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded {
                    Divider().overlay(Palette.hairline(scheme)).padding(.vertical, 11)
                    VStack(spacing: 7) {
                        ForEach(group.findings.prefix(14)) { finding in
                            FindingRow(finding: finding, model: model, tint: tint)
                        }
                        if group.findings.count > 14 {
                            HStack {
                                Text("+ \(group.findings.count - 14) more in Cleanup")
                                    .font(Typo.caption)
                                    .foregroundStyle(Palette.inkTertiary(scheme))
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: hovering) { _, value in
            withAnimation(Motion.tactile) {
                model.focusedCategory = value ? group.category.rawValue : nil
            }
        }
    }
}

struct FindingRow: View {
    let finding: CleanupFinding
    @ObservedObject var model: CleanupModel
    var tint: Color

    @Environment(\.colorScheme) private var scheme
    @State private var showsPaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                ApexCheckbox(
                    isOn: Binding(
                        get: { model.selection.contains(finding.id) },
                        set: { _ in model.toggle(finding) }
                    ),
                    tint: tint
                )
                .disabled(finding.isBlocked)
                .opacity(finding.isBlocked ? 0.4 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(finding.title)
                        .font(Typo.body)
                        .foregroundStyle(finding.isBlocked ? Palette.inkTertiary(scheme) : Palette.ink(scheme))
                    Text(finding.risk.label)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkTertiary(scheme))
                }

                Spacer(minLength: 6)

                if finding.isBlocked {
                    Chip(text: "Quit \(finding.blockedBy.first ?? "app")", tint: Palette.caution, symbol: "hand.raised.fill")
                }

                Text(Bytes.format(finding.bytes))
                    .font(Typo.numeric(12, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .frame(minWidth: 62, alignment: .trailing)

                Button {
                    withAnimation(Motion.tactile) { showsPaths.toggle() }
                } label: {
                    Image(systemName: showsPaths ? "eye.fill" : "eye")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show exact paths")
            }

            if showsPaths {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(finding.items.prefix(6)) { item in
                        HStack(spacing: 6) {
                            Text(item.displayPath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Palette.inkTertiary(scheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Bytes.format(item.bytes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.inkTertiary(scheme).opacity(0.7))
                        }
                    }
                    if finding.items.count > 6 {
                        Text("+ \(finding.items.count - 6) more paths")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkTertiary(scheme).opacity(0.7))
                    }
                }
                .padding(.leading, 26)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .offset(y: -3)))
            }
        }
    }
}
