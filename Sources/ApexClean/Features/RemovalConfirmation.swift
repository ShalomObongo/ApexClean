import ApexCore
import SwiftUI

/// The last thing between a person and a destructive action.
///
/// It exists to answer three questions without making anyone read a list of 600
/// paths: what exactly goes, how much, and what is being skipped. The confirming
/// button never says "OK" — it says what it will do.
struct RemovalConfirmation: View {
    @ObservedObject var model: CleanupModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    var onConfirm: () -> Void

    private var headline: String {
        "Delete \(Bytes.format(model.selectedBytes)) permanently?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.hairline(scheme))
            breakdown
            Divider().overlay(Palette.hairline(scheme))
            irreversibleWarning
            if !model.skippedBlockedFindings.isEmpty {
                skipped
            }
            Divider().overlay(Palette.hairline(scheme))
            actions
        }
        .frame(width: 480)
        .background(Palette.canvas(scheme))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Palette.caution.opacity(0.14))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.caution)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(Typo.metric(18, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "\(Count.files(model.selectedFileCount)) in \(Count.groups(model.selectedFindings.count))."
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var breakdown: some View {
        VStack(spacing: 0) {
            ForEach(model.selectionBreakdown, id: \.category) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.category.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.category(row.category.rawValue))
                        .frame(width: 16)

                    Text(row.category.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink(scheme))

                    Spacer(minLength: 8)

                    Text(Count.files(row.files))
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkTertiary(scheme))

                    Text(Bytes.format(row.bytes))
                        .font(Typo.numeric(12, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
            }
        }
        .padding(.vertical, 4)
    }

    private var irreversibleWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.bin")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.caution)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text("This cannot be undone")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink(scheme))
                Text(
                    "The selected files and folders are deleted directly after their paths and filesystem identities are checked again. History records what was removed, but ApexClean does not provide recovery."
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var skipped: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.caution)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    "\(model.skippedBlockedFindings.count) selected \(model.skippedBlockedFindings.count == 1 ? "group is" : "groups are") in use and will be skipped"
                )
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
                Text("Quit \(blockedAppList) to include them.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 13)
    }

    private var blockedAppList: String {
        let names = Array(Set(model.skippedBlockedFindings.flatMap(\.blockedBy))).sorted()
        return ListPhrase.join(names)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            ApexButton(title: "Cancel", kind: .quiet) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            confirmButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var confirmButton: some View {
        ApexButton(
            title: "Delete Permanently",
            symbol: "trash.slash",
            kind: .destructive
        ) {
            dismiss()
            onConfirm()
        }
    }
}

enum ListPhrase {
    /// "Safari", "Safari and Chrome", "Safari, Chrome and Arc".
    static func join(_ items: [String]) -> String {
        switch items.count {
        case 0: "the app"
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")) and \(items[items.count - 1])"
        }
    }
}
