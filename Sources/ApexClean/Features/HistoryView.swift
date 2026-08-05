import ApexCore
import SwiftUI

/// Full accountability: every session and every path ApexClean has removed.
struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var sessions: [OperationLog.Session] = []
    @State private var entries: [OperationLog.Entry] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if let loadError {
                    errorState(loadError)
                } else if sessions.isEmpty {
                    emptyState
                } else {
                    totals
                    sessionList
                    entryList
                }
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let history = state.history
        Task.detached(priority: .utility) {
            let snapshot = history.snapshot(sessionLimit: 30, entryLimit: 120)
            await MainActor.run {
                switch snapshot {
                case let .success(value):
                    sessions = value.sessions
                    entries = value.entries
                    loadError = nil
                    state.refreshHistory()
                case let .failure(error):
                    sessions = []
                    entries = []
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private var header: some View {
        PageHeader(
            eyebrow: "History",
            title: "Recent activity, fully local",
            subtitle: "The latest sessions and paths from the durable on-device operation log."
        )
    }

    private var totals: some View {
        HStack(spacing: 14) {
            statTile(
                "Handled in total", Bytes.format(state.totalHandledEver), Palette.jade,
                "arrow.down.circle")
            statTile("Recent sessions", "\(sessions.count)", Palette.info, "clock")
            statTile("Recent paths", "\(entries.count)", Palette.cyan, "list.bullet")
        }
    }

    private func statTile(_ label: String, _ value: String, _ tint: Color, _ symbol: String) -> some View {
        ApexCard(padding: 15) {
            HStack(spacing: 11) {
                GlyphTile(symbol: symbol, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkTertiary(scheme))
                    Text(value)
                        .font(Typo.metric(18, weight: .bold))
                        .foregroundStyle(Palette.ink(scheme))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var sessionList: some View {
        VStack(spacing: 8) {
            SectionHeader(eyebrow: "Sessions", title: "Recent activity")
                .padding(.horizontal, 2)
            ForEach(sessions) { session in
                ApexCard(padding: 13) {
                    HStack(spacing: 12) {
                        GlyphTile(symbol: "checkmark.seal", tint: Palette.jade, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .font(Typo.cardTitle)
                                .foregroundStyle(Palette.ink(scheme))
                            Text(
                                "\(Count.items(session.itemCount)) recorded"
                            )
                            .font(Typo.caption)
                            .foregroundStyle(Palette.inkTertiary(scheme))
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Bytes.format(session.bytes))
                                .font(Typo.metric(14, weight: .semibold))
                                .foregroundStyle(Palette.jade)
                            Text(RelativeTime.short(session.date))
                                .font(Typo.caption)
                                .foregroundStyle(Palette.inkTertiary(scheme))
                        }
                    }
                }
            }
        }
    }

    private var entryList: some View {
        VStack(spacing: 8) {
            SectionHeader(
                eyebrow: "Detail",
                title: "Recent paths",
                subtitle: "The latest exact paths handled, most recent first."
            )
            .padding(.horizontal, 2)

            ApexCard(padding: 12) {
                VStack(spacing: 5) {
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Image(
                                systemName: entry.recoverable
                                    ? "archivebox"
                                    : "xmark.circle"
                            )
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                            .help(
                                entry.recoverable
                                    ? "Legacy entry: moved to Trash at the time; current availability is unknown"
                                    : "Removed directly"
                            )
                            Text(Glob.display(entry.path))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Palette.inkSecondary(scheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(Bytes.format(entry.bytes))
                                .font(Typo.numeric(10))
                                .foregroundStyle(Palette.inkTertiary(scheme))
                            Text(RelativeTime.short(entry.date))
                                .font(.system(size: 9.5))
                                .foregroundStyle(Palette.inkTertiary(scheme).opacity(0.7))
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ApexCard(padding: 34) {
            VStack(spacing: 11) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                Text("Nothing removed yet")
                    .font(Typo.metric(16))
                    .foregroundStyle(Palette.ink(scheme))
                Text(
                    "When ApexClean removes something, it will be listed here with its exact path, size, and time."
                )
                .font(Typo.body)
                .foregroundStyle(Palette.inkTertiary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func errorState(_ message: String) -> some View {
        ApexCard(padding: 28, accent: Palette.caution) {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.caution)
                Text("History is unavailable")
                    .font(Typo.metric(16))
                    .foregroundStyle(Palette.ink(scheme))
                Text(message)
                    .font(Typo.body)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .multilineTextAlignment(.center)
                ApexButton(title: "Try again", symbol: "arrow.clockwise", kind: .secondary) {
                    reload()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
