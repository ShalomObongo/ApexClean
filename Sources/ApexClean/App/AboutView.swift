import SwiftUI
import ApexCore

/// About / legal panel.
///
/// GPL-3.0 §5(d) requires an interactive program to display "Appropriate Legal
/// Notices". This is that surface — and because ApexClean's whole proposition
/// is transparency, it is written to actually be read rather than to satisfy a
/// clause: what the app is, what it is built on, and what it does with your
/// data, in plain sentences.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "Version \(short) (\(build))"
    }()

    var body: some View {
        ZStack {
            Palette.canvasDeep(scheme).ignoresSafeArea()

            LinearGradient(
                colors: [Palette.jade.opacity(scheme == .dark ? 0.14 : 0.10), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.hairline(scheme))
                ScrollView { legalBody.padding(28) }
            }
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            AppMark(size: 62)
                .padding(.top, 30)
                .shadow(color: Palette.jade.opacity(0.30), radius: 20, y: 6)

            Text("ApexClean")
                .font(Typo.display(25, weight: .bold))
                .foregroundStyle(Palette.ink(scheme))

            Text("Mac care, transparently")
                .font(Typo.secondary)
                .foregroundStyle(Palette.inkSecondary(scheme))

            Text(Self.version)
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
                .padding(.top, 2)
                .padding(.bottom, 24)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Body

    private var legalBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            section(
                "Free software",
                """
                ApexClean is free software: you can redistribute it and modify \
                it under the terms of the GNU General Public License, version 3 \
                or later, as published by the Free Software Foundation.

                It is distributed in the hope that it will be useful, but \
                WITHOUT ANY WARRANTY — without even the implied warranty of \
                MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the \
                GNU General Public License for more details.
                """
            )

            section(
                "Built on Mole",
                """
                ApexClean's cleanup catalog, path-protection boundaries, \
                leftover-matching rules, maintenance tasks, and health scoring \
                were adapted from the open-source Mole command-line toolkit by \
                Tw93, which is licensed under GPL-3.0. Every part was \
                reimplemented in Swift; no Mole source is redistributed here.

                ApexClean is an independent project. It is not affiliated with \
                or endorsed by Mole, and it is not related to the separate \
                proprietary Mole for Mac application.
                """
            )

            section(
                "Your data stays here",
                """
                ApexClean has no accounts, no telemetry, and no network client. \
                Nothing about your files, your Mac, or your usage leaves this \
                machine. Scans read metadata locally; results are held in \
                memory and in a local operation log you can inspect from the \
                History screen.
                """
            )

            VStack(alignment: .leading, spacing: 9) {
                link("Read the full license", "https://www.gnu.org/licenses/gpl-3.0.html")
                link("ApexClean source code", "https://github.com/ShalomObongo/ApexClean")
                link("Mole, the project this builds on", "https://github.com/tw93/mole")
            }
            .padding(.top, 2)

            Text("Copyright © 2025 The ApexClean Authors.")
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
                .padding(.top, 4)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.ink(scheme))

            Text(text)
                .font(Typo.secondary)
                .foregroundStyle(Palette.inkSecondary(scheme))
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func link(_ label: String, _ urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) { openURL(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                Text(label).font(Typo.secondary.weight(.medium))
            }
            .foregroundStyle(Palette.jade)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
