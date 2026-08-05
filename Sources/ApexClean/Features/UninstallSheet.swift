import ApexCore
import SwiftUI

/// The uninstall review sheet.
///
/// This is the app's most consequential moment, so it shows the *evidence* for
/// every file — not just a list of paths. Name-only matches are visually
/// distinguished from bundle-identifier matches, because they carry more risk of
/// belonging to something else.
struct UninstallSheet: View {
    let plan: UninstallPlan
    @ObservedObject var model: ApplicationsModel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.hairline(scheme))

            if let outcome = model.uninstallOutcome {
                result(outcome)
            } else {
                body(for: plan)
            }

            Divider().overlay(Palette.hairline(scheme))
            footer
        }
        .frame(width: 620, height: 620)
        .background(Palette.canvas(scheme))
        .interactiveDismissDisabled(model.isUninstalling)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: plan.app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("Uninstall \(plan.app.name)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink(scheme))
                Text("\(plan.app.version) · \(plan.app.bundleID)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(Bytes.format(model.planSelectedBytes))
                    .font(Typo.metric(20, weight: .bold))
                    .foregroundStyle(Palette.info)
                Text("selected")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func body(for plan: UninstallPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if case let .refused(reason) = plan.uninstallVerdict {
                    warning(
                        symbol: "hand.raised.fill",
                        tint: Palette.caution,
                        title: "ApexClean will not remove this app",
                        detail: reason
                    )
                }

                if plan.app.isRunning {
                    warning(
                        symbol: "exclamationmark.triangle.fill",
                        tint: Palette.caution,
                        title: "\(plan.app.name) is running",
                        detail:
                            "Quit it before uninstalling. Removing a live app's files can leave background helpers behind."
                    )
                }

                bundleSection(plan)

                if plan.leftovers.isEmpty {
                    Text("No supporting files found outside the bundle.")
                        .font(Typo.body)
                        .foregroundStyle(Palette.inkTertiary(scheme))
                } else {
                    ForEach(plan.grouped, id: \.kind) { section in
                        leftoverSection(section.kind, items: section.items)
                    }
                }

                warning(
                    symbol: "exclamationmark.triangle.fill",
                    tint: Palette.caution,
                    title: "This uninstall is permanent",
                    detail:
                        "The checked application bundle and supporting files are deleted directly after final safety and identity checks. ApexClean records the paths in History but does not provide recovery."
                )

                if !plan.requiresAdmin.isEmpty {
                    warning(
                        symbol: "exclamationmark.shield",
                        tint: Palette.caution,
                        title: "\(Count.files(plan.requiresAdmin.count)) require separate review",
                        detail: "These identifier-bound files sit outside ApexClean's writable "
                            + "roots. Use the vendor's official uninstaller or inspect them "
                            + "manually; ApexClean will not generate a bypass command.\n"
                            + plan.requiresAdmin.map { "  \(Glob.display($0.url.path))" }
                            .joined(separator: "\n")
                    )
                }

                if !plan.unmeasurable.isEmpty {
                    warning(
                        symbol: "lock.circle",
                        tint: Palette.caution,
                        title: "\(plan.unmeasurable.count) folders could not be measured",
                        detail:
                            "macOS keeps sandbox containers and a few other stores private unless ApexClean has Full Disk Access. They are listed and will still be removed — only the size is unknown, so the total above is a floor."
                    )
                }
            }
            .padding(20)
        }
    }

    private func bundleSection(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Application").eyebrowStyle(scheme)
            row(
                id: plan.bundle.path,
                title: plan.bundle.lastPathComponent,
                path: Glob.display(plan.bundle.path),
                evidence: "The application bundle itself",
                bytes: plan.app.bundleBytes,
                symbol: "app.fill",
                tint: Palette.jade,
                strong: true
            )
        }
    }

    private func leftoverSection(_ kind: Leftover.Kind, items: [Leftover]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(kind.rawValue).eyebrowStyle(scheme)
                Spacer()
                Text(Bytes.format(items.reduce(0) { $0 + $1.bytes }))
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
            ForEach(items) { item in
                row(
                    id: item.id,
                    title: item.url.lastPathComponent,
                    path: item.displayPath,
                    evidence: item.evidence,
                    bytes: item.bytes,
                    sizeIsUnknown: item.sizeIsUnknown,
                    symbol: kind.symbol,
                    tint: item.evidence.contains("bundle identifier") ? Palette.jade : Palette.caution,
                    strong: false
                )
            }
        }
    }

    private func row(
        id: String,
        title: String,
        path: String,
        evidence: String,
        bytes: Int64,
        sizeIsUnknown: Bool = false,
        symbol: String,
        tint: Color,
        strong: Bool
    ) -> some View {
        HStack(spacing: 10) {
            ApexCheckbox(
                isOn: Binding(
                    get: { model.planSelection.contains(id) },
                    set: { on in
                        if on { model.planSelection.insert(id) } else { model.planSelection.remove(id) }
                    }
                ),
                tint: tint,
                label: title
            )

            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: strong ? .semibold : .regular))
                    .foregroundStyle(Palette.ink(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(evidence)
                    .font(.system(size: 10))
                    .foregroundStyle(tint.opacity(0.85))
            }

            Spacer(minLength: 6)

            if sizeIsUnknown {
                Text("Size unknown")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .help("macOS keeps this folder private unless ApexClean has Full Disk Access.")
            } else {
                Text(Bytes.format(bytes))
                    .font(Typo.numeric(11, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary(scheme))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.surface(scheme).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.hairline(scheme), lineWidth: 1)
        )
    }

    private func warning(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink(scheme))
                Text(detail)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    private func result(_ outcome: Remover.Outcome) -> some View {
        let complete =
            !outcome.removed.isEmpty
            && outcome.failed.isEmpty
            && outcome.refused.isEmpty
        let partial = !outcome.removed.isEmpty && !complete

        return VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill((complete ? Palette.jade : Palette.caution).opacity(0.13))
                    .frame(width: 70, height: 70)
                Image(systemName: complete ? "checkmark" : "exclamationmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(complete ? Palette.info : Palette.caution)
            }
            Text(resultTitle(outcome, complete: complete, partial: partial))
                .font(Typo.metric(22, weight: .bold))
                .foregroundStyle(Palette.ink(scheme))
            Text(resultDetail(outcome))
                .font(Typo.body)
                .foregroundStyle(Palette.inkSecondary(scheme))
            if !outcome.refused.isEmpty || !outcome.failed.isEmpty {
                ApexCard(padding: 12, accent: Palette.caution) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(outcome.refused.enumerated()), id: \.offset) { _, item in
                                issueLine(path: item.url, reason: item.reason)
                            }
                            ForEach(Array(outcome.failed.enumerated()), id: \.offset) { _, item in
                                issueLine(path: item.url, reason: item.error)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func issueLine(path: URL, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Glob.display(path.path))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.inkSecondary(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(reason)
                .font(Typo.caption)
                .foregroundStyle(Palette.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultTitle(
        _ outcome: Remover.Outcome,
        complete: Bool,
        partial: Bool
    ) -> String {
        if !complete {
            return partial ? "Uninstall only partly completed" : "Nothing was removed"
        }
        return "Removed \(Bytes.format(outcome.bytesProcessed))"
    }

    private func resultDetail(_ outcome: Remover.Outcome) -> String {
        var parts: [String] = []
        if !outcome.removed.isEmpty {
            parts.append("\(Count.items(outcome.removed.count)) deleted")
        }
        if !outcome.refused.isEmpty {
            parts.append("\(outcome.refused.count) refused by safety checks")
        }
        if !outcome.failed.isEmpty {
            parts.append("\(outcome.failed.count) failed")
        }
        return parts.isEmpty ? "The reviewed scope was left unchanged" : parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            if model.uninstallOutcome == nil {
                Text("\(model.planSelection.count) of \(plan.leftovers.count + 1) items selected")
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
            Spacer()
            if model.uninstallOutcome == nil {
                ApexButton(title: "Cancel", kind: .quiet) {
                    dismiss(); model.dismissPlan()
                }
                .disabled(model.isUninstalling)
                ApexButton(
                    title: "Delete Permanently",
                    symbol: "trash.slash",
                    kind: .destructive,
                    isLoading: model.isUninstalling
                ) {
                    model.performUninstall()
                }
                .disabled(
                    model.planSelection.isEmpty
                        || model.isUninstalling
                        || plan.app.isRunning
                        || !plan.uninstallVerdict.isAllowed
                )
            } else {
                ApexButton(title: "Done", kind: .primary) {
                    dismiss(); model.dismissPlan()
                }
            }
        }
        .padding(16)
    }
}
