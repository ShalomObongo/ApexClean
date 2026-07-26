import SwiftUI
import ApexCore

/// The last thing between a person and a destructive action.
///
/// It exists to answer four questions without making anyone read a list of 600
/// paths: what exactly goes, how much, whether it comes back, and what is being
/// skipped. The confirming button never says "OK" — it says what it will do.
struct RemovalConfirmation: View {
    @ObservedObject var model: CleanupModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    var onConfirm: () -> Void

    private var permanent: Bool { model.removalIsPermanent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.hairline(scheme))
            breakdown
            Divider().overlay(Palette.hairline(scheme))
            recovery
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
                    .fill((permanent ? Palette.caution : Palette.jade).opacity(0.14))
                Image(systemName: permanent ? "exclamationmark.triangle.fill" : "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(permanent ? Palette.caution : Palette.jade)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(permanent ? "Delete \(Bytes.format(model.selectedBytes)) permanently?"
                               : "Move \(Bytes.format(model.selectedBytes)) to the Trash?")
                    .font(Typo.metric(18, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(Count.files(model.selectedFileCount)) in \(Count.groups(model.selectedFindings.count)).")
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

    private var recovery: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permanent ? "xmark.bin" : "arrow.uturn.backward")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(permanent ? Palette.caution : Palette.positive)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(permanent ? "This cannot be undone" : "You can put it back")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink(scheme))
                Text(permanent
                     ? "Items already in the Trash cannot be moved to the Trash again, so these are erased from disk."
                     : "Everything goes to the Trash with its original location intact, and every path is recorded in History.")
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
                Text("\(model.skippedBlockedFindings.count) selected \(model.skippedBlockedFindings.count == 1 ? "group is" : "groups are") in use and will be skipped")
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
            ApexButton(title: "Cancel", kind: .quiet) { dismiss() }
                .keyboardShortcut(.cancelAction)
            ApexButton(
                title: permanent ? "Delete Permanently" : "Move to Trash",
                symbol: "trash",
                kind: .primary
            ) {
                dismiss()
                onConfirm()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
