import ApexCore
import SwiftUI

struct MaintenanceView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Injected by RootView and observed directly. A nested
    /// `ObservableObject` reached through `@EnvironmentObject` publishes
    /// nothing to this view, so the model must be observed here.
    @ObservedObject var model: MaintenanceModel
    @State private var isConfirmingDestructiveRun = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if !model.results.isEmpty { summary }
                grid
                    .disabled(model.isRunning)
                honesty
            }
            .alert("Run irreversible maintenance?", isPresented: $isConfirmingDestructiveRun) {
                Button("Cancel", role: .cancel) {}
                Button("Run Permanently", role: .destructive) { model.run() }
            } message: {
                Text(
                    "\(model.selectedDestructiveTasks.map(\.title).joined(separator: ", ")). These tasks permanently delete the specific cache, preference, saved-state or launch-agent files they validate. ApexClean does not provide recovery."
                )
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        PageHeader(
            eyebrow: "Maintenance",
            title: "Bounded, explainable tasks",
            subtitle:
                "Each task states exactly what it does. None of them claim to make your Mac faster on their own."
        ) {
            ApexButton(
                title: model.isRunning
                    ? "Running \(model.completedCount)/\(model.queuedCount)"
                    : "Run \(model.selection.count) selected",
                symbol: "play.fill",
                kind: .primary,
                isLoading: model.isRunning
            ) {
                if model.selectedDestructiveTasks.isEmpty {
                    model.run()
                } else {
                    isConfirmingDestructiveRun = true
                }
            }
            .disabled(model.selection.isEmpty || model.isRunning)
        }
    }

    private var summary: some View {
        ApexCard(padding: 16, accent: Palette.jade) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill((model.hasFailures ? Palette.caution : Palette.jade).opacity(0.13))
                        .frame(width: 40, height: 40)
                    Image(
                        systemName: model.isRunning
                            ? "gearshape.2"
                            : (model.hasFailures ? "exclamationmark" : "checkmark")
                    )
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(model.hasFailures ? Palette.caution : Palette.info)
                    .symbolEffect(.pulse, isActive: model.isRunning)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        model.isRunning
                            ? "Working through the queue"
                            : (model.hasFailures
                                ? "Maintenance finished with issues" : "Maintenance complete")
                    )
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.ink(scheme))
                    Text(
                        model.totalFreed > 0
                            ? "\(model.completedCount) tasks finished · \(Bytes.format(model.totalFreed)) reclaimed"
                            : "\(model.completedCount) tasks finished"
                    )
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                }
                Spacer()
                if !model.isRunning {
                    ApexButton(title: "Clear", kind: .quiet, size: .compact) { model.reset() }
                }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 380), spacing: 12)],
            spacing: 12
        ) {
            ForEach(model.tasks) { task in
                TaskCard(
                    task: task,
                    isSelected: model.selection.contains(task.id),
                    isRunning: model.running == task.id,
                    result: model.results[task.id],
                    onToggle: { model.toggle(task) }
                )
            }
        }
    }

    private var honesty: some View {
        ApexCard(padding: 15) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.info)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What maintenance actually does")
                        .font(Typo.cardTitle)
                        .foregroundStyle(Palette.ink(scheme))
                    Text(
                        "macOS already runs its own periodic maintenance and manages memory well on its own. These tasks repair specific broken states — a stale cache, a preference file an app can no longer read, a startup item pointing at a program that no longer exists. They are useful when something is wrong, and largely a no-op when nothing is. ApexClean will tell you which of those happened."
                    )
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct TaskCard: View {
    let task: MaintenanceTask
    let isSelected: Bool
    let isRunning: Bool
    let result: MaintenanceResult?
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var showsMechanism = false

    var body: some View {
        ApexCard(padding: 14, interactive: true, accent: accent) {
            VStack(alignment: .leading, spacing: 9) {
                // The whole row toggles, not just the box. Aiming at a 16pt
                // square to choose a task is a needless precision test, and
                // every other row-with-a-checkbox in the app reads as clickable.
                Button(action: { if !isRunning { onToggle() } }) {
                    HStack(spacing: 11) {
                        ApexCheckbox(
                            isOn: Binding(get: { isSelected }, set: { _ in onToggle() }),
                            label: task.title
                        )
                        .disabled(isRunning)
                        .allowsHitTesting(false)

                        GlyphTile(symbol: task.symbol, tint: accent ?? Palette.info, size: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.ink(scheme))
                            Text(task.summary)
                                .font(Typo.secondary)
                                .foregroundStyle(Palette.inkTertiary(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 4)

                        if isRunning {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        } else if let result {
                            Image(
                                systemName: result.succeeded
                                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                            )
                            .font(.system(size: 14))
                            .foregroundStyle(result.succeeded ? Palette.jade : Palette.caution)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .accessibilityLabel(task.title)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityHint(task.summary)
                .accessibilityAddTraits(.isToggle)

                if let result {
                    HStack(spacing: 6) {
                        Text(result.detail)
                            .font(Typo.caption)
                            .foregroundStyle(result.succeeded ? Palette.jade : Palette.caution)
                        Spacer()
                    }
                    .padding(.leading, 41)
                }

                HStack(spacing: 8) {
                    Button {
                        withAnimation(Motion.tactile) { showsMechanism.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "info.circle").font(.system(size: 9))
                            Text(showsMechanism ? "Hide detail" : "What it does")
                        }
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkTertiary(scheme))
                    }
                    .buttonStyle(.plain)

                    if task.requiresAdmin {
                        Chip(text: "May need admin", tint: Palette.caution, symbol: "lock")
                    }
                    Spacer()
                    Text("~\(task.estimatedSeconds)s")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkTertiary(scheme))
                }
                .padding(.leading, 41)

                if showsMechanism {
                    Text(task.mechanism)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 41)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                }
            }
        }
    }

    private var accent: Color? {
        if isRunning { return Palette.cyan }
        guard let result else { return isSelected ? Palette.jade : nil }
        return result.succeeded ? Palette.jade : Palette.caution
    }
}
