import ApexCore
import SwiftUI

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

    /// True when nothing from this pass will be recoverable afterwards.
    private var isDestructive: Bool {
        permanent || model.selectionMixesTrash || model.emptiesTrashAfterCleaning
    }

    private var headline: String {
        let size = Bytes.format(model.selectedBytes)
        if model.emptiesTrashAfterCleaning {
            // Only add the Trash figure when it is actually known. Padding the
            // headline with a number we could not measure would be theatre.
            if case let .holding(bytes, _) = model.trashState {
                let total = Bytes.format(model.selectedBytes + bytes - model.selectedTrashBytes)
                return "Erase \(total) with no way back?"
            }
            return "Erase \(size) and the Trash, with no way back?"
        }
        if model.selectionMixesTrash {
            return "Move most items and permanently erase \(Bytes.format(model.selectedTrashBytes))?"
        }
        return permanent ? "Delete \(size) permanently?" : "Move \(size) to the Trash?"
    }

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
            emptyTrashOption
            Divider().overlay(Palette.hairline(scheme))
            actions
        }
        .frame(width: 480)
        .background(Palette.canvas(scheme))
        .onDisappear {
            if model.stage != .cleaning {
                model.emptiesTrashAfterCleaning = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill((isDestructive ? Palette.caution : Palette.jade).opacity(0.14))
                Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isDestructive ? Palette.caution : Palette.jade)
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

    private var recovery: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isDestructive ? "xmark.bin" : "arrow.uturn.backward")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isDestructive ? Palette.caution : Palette.positive)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(recoveryTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink(scheme))
                Text(recoveryDetail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var recoveryTitle: String {
        if model.emptiesTrashAfterCleaning || permanent { return "This cannot be undone" }
        return model.selectionMixesTrash ? "Most of this can be put back" : "You can put it back"
    }

    private var recoveryDetail: String {
        if model.emptiesTrashAfterCleaning {
            return
                "You chose to empty the Trash as part of this pass, so nothing here survives it. Readable paths are recorded in History; Finder also empties per-volume Trash."
        }
        if permanent {
            return
                "Items already in the Trash cannot be moved to the Trash again, so these are erased from disk."
        }
        if model.selectionMixesTrash {
            return
                "Everything goes to the Trash except the \(Bytes.format(model.selectedTrashBytes)) already in it, which is erased — the Trash cannot hold itself twice."
        }
        return
            "Everything goes to the Trash with its original location intact, and every path is recorded in History."
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

    /// Offered here rather than folded into the cleanup itself. Emptying the
    /// Trash is the one action in this app with no way back, so it is opt-in
    /// every time and says plainly that it also takes what is being moved there
    /// by this very pass.
    private var emptyTrashOption: some View {
        Button {
            model.emptiesTrashAfterCleaning.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ApexCheckbox(
                    isOn: $model.emptiesTrashAfterCleaning,
                    tint: Palette.caution,
                    label: "Empty the Trash afterwards"
                )
                .allowsHitTesting(false)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Empty the Trash afterwards")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.ink(scheme))
                        if case let .holding(bytes, _) = model.trashState {
                            Text("+\(Bytes.format(bytes))")
                                .font(Typo.numeric(11, weight: .semibold))
                                .foregroundStyle(Palette.caution)
                        }
                    }
                    Text(emptyTrashExplanation)
                        .font(Typo.caption)
                        .foregroundStyle(
                            model.emptiesTrashAfterCleaning
                                ? Palette.caution
                                : Palette.inkTertiary(scheme)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .accessibilityLabel("Empty the Trash afterwards")
        .accessibilityValue(model.emptiesTrashAfterCleaning ? "On" : "Off")
        .accessibilityHint(emptyTrashExplanation)
        .accessibilityAddTraits(.isToggle)
    }

    private var emptyTrashExplanation: String {
        if model.emptiesTrashAfterCleaning {
            return permanent
                ? "The Trash will be erased. Nothing from this pass can be recovered."
                : "Everything above is moved to the Trash and then erased with it. Nothing from this pass can be recovered."
        }
        switch model.trashState {
        case let .holding(bytes, items):
            return
                "\(Bytes.format(bytes)) in \(items) \(items == 1 ? "item" : "items") is already sitting in the Trash. Leave this off to keep today's cleanup recoverable."
        case .empty:
            return "The Trash is empty, so this would only erase what this pass puts there."
        case .unreadable:
            return
                "macOS keeps the Trash private unless ApexClean has Full Disk Access, so its size is unknown. Finder will empty it."
        }
    }

    private var blockedAppList: String {
        let names = Array(Set(model.skippedBlockedFindings.flatMap(\.blockedBy))).sorted()
        return ListPhrase.join(names)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            ApexButton(title: "Cancel", kind: .quiet) {
                model.emptiesTrashAfterCleaning = false
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            confirmButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var confirmButton: some View {
        let button = ApexButton(
            title: confirmTitle,
            symbol: "trash",
            kind: isDestructive ? .destructive : .primary
        ) {
            dismiss()
            onConfirm()
        }
        if isDestructive {
            button
        } else {
            button.keyboardShortcut(.defaultAction)
        }
    }

    private var confirmTitle: String {
        if model.emptiesTrashAfterCleaning { return "Remove and Empty Trash" }
        return permanent ? "Delete Permanently" : "Move to Trash"
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
