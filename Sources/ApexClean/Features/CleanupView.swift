import ApexCore
import SwiftUI

/// The expert surface: every finding, every path, per-category filtering.
struct CleanupView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Injected by RootView and observed directly. A nested
    /// `ObservableObject` reached through `@EnvironmentObject` publishes
    /// nothing to this view, so the model must be observed here.
    @ObservedObject var model: CleanupModel

    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 16)

            if model.stage == .scanning {
                StateView(kind: .working("Scanning \(model.progress.currentTitle)…"))
            } else if model.report.isEmpty {
                emptyState
            } else {
                content
            }

            if model.selectedBytes > 0 {
                actionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.enter, value: model.selectedBytes > 0)
        .sheet(isPresented: $isConfirming) {
            RemovalConfirmation(model: model) { model.clean() }
        }
    }

    private var header: some View {
        PageHeader(
            eyebrow: "Cleanup",
            title: "Choose exactly what goes",
            subtitle: model.report.isEmpty
                ? "Run a scan to populate this list."
                : "\(Bytes.format(model.report.totalBytes)) found across \(model.report.groups.count) categories. Expand any row to see the exact paths."
        ) {
            HStack(spacing: 8) {
                if model.stage == .scanning {
                    ApexButton(title: "Stop", symbol: "stop.fill", kind: .secondary) { model.cancelScan() }
                } else {
                    ApexButton(title: "Rescan", symbol: "arrow.clockwise", kind: .secondary) { model.scan() }
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let outcome = model.lastOutcome,
                    (!outcome.failed.isEmpty || !outcome.refused.isEmpty)
                {
                    cleanupFailureNotice(outcome)
                }
                if !model.report.stalledRules.isEmpty {
                    incompleteScanNotice
                }
                categoryFilter
                ForEach(model.report.groups) { group in
                    DetailedGroupCard(group: group, model: model)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
    }

    private func cleanupFailureNotice(_ outcome: Remover.Outcome) -> some View {
        ApexCard(padding: 15, accent: Palette.caution) {
            VStack(alignment: .leading, spacing: 6) {
                Text(outcome.removed.isEmpty ? "Cleanup did not start" : "Cleanup finished with issues")
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.ink(scheme))
                ForEach(Array(outcome.failed.enumerated()), id: \.offset) { _, item in
                    Text(item.error)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.caution)
                }
                ForEach(Array(outcome.refused.enumerated()), id: \.offset) { _, item in
                    Text(item.reason)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.caution)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var incompleteScanNotice: some View {
        ApexCard(padding: 15, accent: Palette.caution) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.caution)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan incomplete")
                        .font(Typo.cardTitle)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(
                        "Some locations stopped responding and were skipped: "
                            + model.report.stalledRules.prefix(4).joined(separator: ", ")
                            + (model.report.stalledRules.count > 4 ? "…" : "")
                            + ". The findings below are still safe to review, but they are not a complete result."
                    )
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var categoryFilter: some View {
        FlowLayout(spacing: 7, lineSpacing: 7) {
            ForEach(CleanupCategory.allCases) { category in
                let enabled = model.enabledCategories.contains(category)
                let tint = Palette.category(category.rawValue)
                Button {
                    withAnimation(Motion.tactile) {
                        if enabled, model.enabledCategories.count > 1 {
                            model.enabledCategories.remove(category)
                        } else {
                            model.enabledCategories.insert(category)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: category.symbol).font(.system(size: 9, weight: .bold))
                        Text(category.title).font(Typo.caption)
                    }
                    .foregroundStyle(enabled ? tint : Palette.inkTertiary(scheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(enabled ? tint.opacity(0.13) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
                            enabled ? tint.opacity(0.3) : Palette.hairline(scheme),
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
                .help(enabled ? "Included in scans" : "Excluded from scans")
            }
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.info)
            Text(emptyTitle)
                .font(Typo.metric(18))
                .foregroundStyle(Palette.ink(scheme))
            Text(
                emptyMessage
            )
            .font(Typo.body)
            .foregroundStyle(Palette.inkTertiary(scheme))
            .multilineTextAlignment(.center)
            ApexButton(
                title: model.stage == .finished ? "Scan again" : "Scan now",
                symbol: "scope",
                size: .large
            ) { model.scan() }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !model.report.stalledRules.isEmpty { return "Scan incomplete" }
        return model.stage == .finished ? "Nothing to clean" : "Nothing scanned yet"
    }

    private var emptyMessage: String {
        if !model.report.stalledRules.isEmpty {
            return
                "Some locations stopped responding, so this is not a complete result. Review the skipped locations and scan again."
        }
        return model.stage == .finished
            ? "The scan finished without finding any selected cleanup targets."
            : "ApexClean never inspects your Mac in the background.\nRun a scan when you want to see what can be reclaimed."
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Bytes.format(model.selectedBytes)) selected")
                    .font(Typo.metric(16, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))
                Text(
                    "\(Count.files(model.selectedFileCount)) across \(Count.groups(model.selectedFindings.count)) · deleted permanently"
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
            }

            Spacer()

            ApexButton(title: "Clear", kind: .quiet) { model.selectNone() }
            ApexButton(
                title: model.stage == .cleaning ? "Deleting…" : "Delete selected",
                symbol: "trash.slash",
                kind: .destructive,
                isLoading: model.stage == .cleaning
            ) {
                model.refreshRunningBlockers()
                if model.selectedBytes > 0 { isConfirming = true }
            }
            .disabled(model.stage == .cleaning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Palette.surface(scheme))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.contour(scheme)).frame(height: 1)
        }
    }
}

private struct DetailedGroupCard: View {
    let group: CleanupGroup
    @ObservedObject var model: CleanupModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let selection = model.selectionState(for: group)
        let tint = Palette.category(group.category.rawValue)

        ApexCard(padding: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ApexCheckbox(
                        isOn: Binding(get: { selection.isOn }, set: { _ in model.toggle(group: group) }),
                        tint: tint,
                        isMixed: selection.isMixed,
                        label: group.category.title
                    )
                    GlyphTile(symbol: group.category.symbol, tint: tint, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.category.title)
                            .font(Typo.cardTitle)
                            .foregroundStyle(Palette.ink(scheme))
                        Text(group.category.subtitle)
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkTertiary(scheme))
                    }
                    Spacer(minLength: 8)
                    Text(Bytes.format(group.bytes))
                        .font(Typo.metric(16, weight: .bold))
                        .foregroundStyle(tint)
                }

                SegmentedBar(
                    segments: group.findings.prefix(12).map {
                        .init(id: $0.id, bytes: $0.bytes, color: tint)
                    },
                    total: group.bytes,
                    height: 4
                )

                Divider().overlay(Palette.hairline(scheme))

                VStack(spacing: 8) {
                    ForEach(group.findings) { finding in
                        FindingRow(finding: finding, model: model, tint: tint)
                    }
                }
            }
        }
    }
}
