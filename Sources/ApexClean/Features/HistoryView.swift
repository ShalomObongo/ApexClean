import ApexCore
import SwiftUI

/// Full accountability: every session and every path ApexClean has removed.
struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var sessions: [OperationLog.Session] = []
    @State private var entries: [OperationLog.Entry] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if sessions.isEmpty {
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
            let sessions = history.recentSessions(limit: 30)
            let entries = history.recentEntries(limit: 120)
            await MainActor.run {
                self.sessions = sessions
                self.entries = entries
                state.refreshHistory()
            }
        }
    }

    private var header: some View {
        PageHeader(
            eyebrow: "History",
            title: "Recent activity, fully local",
            subtitle: "The latest sessions and paths from the durable on-device operation log."
        ) {
            ApexButton(title: "Reveal Trash", symbol: "trash", kind: .secondary) {
                NSWorkspace.shared.open(PathGuard.home.appendingPathComponent(".Trash"))
            }
        }
    }

    private var totals: some View {
        HStack(spacing: 14) {
            statTile(
                "Handled in total", Bytes.format(state.totalHandledEver), Palette.jade,
                "arrow.down.circle")
            statTile("Recent sessions", "\(sessions.count)", Palette.info, "clock")
            statTile(
                "Recoverable",
                "\(sessions.reduce(0) { $0 + $1.recoverableCount })",
                Palette.cyan,
                "arrow.uturn.backward"
            )
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
                                "\(Count.items(session.itemCount)) · \(session.recoverableCount) recoverable from Trash"
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
                                systemName: entry.recoverable ? "arrow.uturn.backward.circle" : "xmark.circle"
                            )
                            .font(.system(size: 9))
                            .foregroundStyle(entry.recoverable ? Palette.jade : Palette.inkTertiary(scheme))
                            .help(entry.recoverable ? "In the Trash" : "Removed directly")
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
                    "When ApexClean removes something, it will be listed here with its exact path, size, and whether it can be restored from the Trash."
                )
                .font(Typo.body)
                .foregroundStyle(Palette.inkTertiary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
