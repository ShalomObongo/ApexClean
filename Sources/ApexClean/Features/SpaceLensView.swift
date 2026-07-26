import ApexCore
import SwiftUI

struct SpaceLensView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Injected by RootView and observed directly. A nested
    /// `ObservableObject` reached through `@EnvironmentObject` publishes
    /// nothing to this view, so the model must be observed here.
    @ObservedObject var model: SpaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 14)

            if model.isScanning {
                scanning
            } else if let stalled = model.stalledPath {
                stalledState(stalled)
            } else if model.root == nil {
                emptyState
            } else {
                HStack(spacing: 0) {
                    treemapPane
                    Divider().overlay(Palette.hairline(scheme))
                    detailPane.frame(width: 288)
                }
            }
        }
    }

    private var privacyInvite: some View {
        PrivacyInviteCard(
            title: "Personal folders are excluded",
            detail:
                "Desktop, Documents and Downloads are skipped so mapping your Home folder never raises a permission dialog on its own.",
            scopes: [.downloads, .desktop, .documents],
            isEnabled: Binding(
                get: { model.includesProtectedLocations },
                set: { model.includesProtectedLocations = $0 }
            ),
            onEnable: { model.scan(model.scanRoot) }
        )
    }

    private var header: some View {
        PageHeader(
            eyebrow: "Space Lens",
            title: "See where storage went",
            subtitle: model.root.map {
                "\(Bytes.format($0.bytes)) in \(Glob.display($0.url.path)). Click a tile to inspect it, double-click to go deeper."
            } ?? "Map any folder by actual size on disk."
        ) {
            HStack(spacing: 8) {
                ApexButton(title: "Choose folder…", symbol: "folder", kind: .secondary) {
                    model.chooseFolder()
                }
                if model.isScanning {
                    ApexButton(title: "Stop", symbol: "stop.fill", kind: .secondary) { model.cancel() }
                } else {
                    ApexButton(title: "Analyse Home", symbol: "house", kind: .primary) {
                        model.scan(PathGuard.home)
                    }
                }
            }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Palette.accentGradient)
            Text("Nothing mapped yet")
                .font(Typo.metric(18))
                .foregroundStyle(Palette.ink(scheme))
            Text(
                "Space Lens measures allocated size — the space you actually get back —\nand every removal goes to the Trash."
            )
            .font(Typo.body)
            .foregroundStyle(Palette.inkTertiary(scheme))
            .multilineTextAlignment(.center)
            ApexButton(title: "Analyse Home folder", symbol: "house", size: .large) {
                model.scan(PathGuard.home)
            }
            .padding(.top, 4)
            privacyInvite
                .frame(maxWidth: 620)
                .padding(.top, 10)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when a folder stopped responding mid-scan. It names the folder,
    /// says plainly that nothing was changed, and offers the one action that
    /// actually helps — measure again without it.
    private func stalledState(_ path: String) -> some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Palette.caution)
            Text("A folder stopped responding")
                .font(Typo.metric(18))
                .foregroundStyle(Palette.ink(scheme))
            Text(Glob.display(path))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.inkSecondary(scheme))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
            Text(
                "Measuring stopped here, so no map was produced. Nothing on your Mac was\nchanged. This usually means a synced or removable folder is offline."
            )
            .font(Typo.body)
            .foregroundStyle(Palette.inkTertiary(scheme))
            .multilineTextAlignment(.center)
            ApexButton(title: "Measure again without it", symbol: "arrow.clockwise", size: .large) {
                model.retryWithoutStalledPath()
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Measuring \(model.scannedPaths) folders")
                .font(Typo.metric(16))
                .foregroundStyle(Palette.ink(scheme))
            Text(model.currentPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.inkTertiary(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 460)
            ApexButton(title: "Stop", kind: .quiet) { model.cancel() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Treemap

    private var treemapPane: some View {
        VStack(spacing: 10) {
            breadcrumb
            if !model.unreadablePaths.isEmpty { unreadableNote }
            GeometryReader { geometry in
                let tiles = Treemap.layout(
                    model.tiles,
                    in: CGRect(origin: .zero, size: geometry.size)
                )
                ZStack(alignment: .topLeading) {
                    ForEach(tiles) { tile in
                        TreemapTile(
                            tile: tile,
                            isHovered: model.hovered == tile.node,
                            isSelected: model.selected == tile.node,
                            depth: depthIndex(for: tile.node)
                        )
                        .frame(width: max(1, tile.rect.width), height: max(1, tile.rect.height))
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                        .accessibilityElement()
                        .accessibilityLabel("\(tile.node.name), \(Bytes.format(tile.node.bytes))")
                        .accessibilityValue(model.selected == tile.node ? "Selected" : "")
                        .accessibilityHint(
                            tile.node.hasChildren ? "Opens this folder in the map" : "Selects this item"
                        )
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.drill(into: tile.node) }
                        .contextMenu {
                            Button("Reveal in Finder") { model.revealInFinder(tile.node) }
                            if tile.node.hasChildren {
                                Button("Open here") { model.drill(into: tile.node) }
                            }
                            Divider()
                            Button("Move to Trash", role: .destructive) {
                                model.moveToTrash(tile.node)
                            }
                        }
                    }
                }
                // The map is one interactive surface, not several hundred.
                // Per-tile gestures were unreliable here: each tile is placed
                // with `offset`, so its hit region lives outside the stack's
                // own bounds, and stacking a tap recogniser on every tile also
                // meant hundreds of recognisers competing for one click.
                // Hit-testing the laid-out rectangles directly is exact,
                // costs one gesture, and cannot drift from what is drawn.
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            if let node = hitTest(tiles, value.location) {
                                model.drill(into: node)
                            }
                        }
                        .exclusively(
                            before: SpatialTapGesture().onEnded { value in
                                if let node = hitTest(tiles, value.location) {
                                    model.select(node)
                                } else {
                                    model.selected = nil
                                }
                            }
                        )
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): model.hovered = hitTest(tiles, point)
                    case .ended: model.hovered = nil
                    }
                }
                .animation(Motion.stage, value: model.tiles.map(\.id))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.hairline(scheme), lineWidth: 1)
            )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    /// A map that quietly omits storage is a map that lies. When a folder does
    /// not answer, the total is understated — so say so, plainly, and name the
    /// folders rather than hinting at them.
    private var unreadableNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.unreadablePaths.count == 1
                        ? "1 folder didn’t respond and isn’t counted here"
                        : "\(model.unreadablePaths.count) folders didn’t respond and aren’t counted here"
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.ink(scheme))
                Text(model.unreadablePaths.prefix(3).map(Glob.display).joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.caution.opacity(0.09))
        )
        .accessibilityElement(children: .combine)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            if model.current?.parent != nil {
                IconButton(symbol: "chevron.left", help: "Go up") { model.ascend() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Palette.inkTertiary(scheme))
                        }
                        Button {
                            model.navigate(to: node)
                        } label: {
                            Text(node.name)
                                .font(
                                    .system(
                                        size: 11.5,
                                        weight: index == model.breadcrumb.count - 1 ? .semibold : .regular)
                                )
                                .foregroundStyle(
                                    index == model.breadcrumb.count - 1
                                        ? Palette.ink(scheme)
                                        : Palette.inkSecondary(scheme)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
        }
        .frame(height: 26)
    }

    private func depthIndex(for node: SpaceNode) -> Int {
        abs(node.name.hashValue) % 6
    }

    /// Topmost tile under a point. Tiles are drawn in descending size order,
    /// so the search runs backwards to match what the eye sees on top.
    private func hitTest(_ tiles: [Treemap.Tile], _ point: CGPoint) -> SpaceNode? {
        tiles.reversed().first { $0.rect.contains(point) }?.node
    }

    // MARK: - Detail

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = model.selected ?? model.hovered {
                    nodeDetail(node)
                } else {
                    childList
                }

                if !model.largeFiles.isEmpty {
                    Divider().overlay(Palette.hairline(scheme))
                    largeFileList
                }
            }
            .padding(18)
        }
    }

    private func nodeDetail(_ node: SpaceNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.selected == nil ? "Pointing at" : "Selected").eyebrowStyle(scheme)
                Spacer(minLength: 6)
                if model.selected != nil {
                    IconButton(symbol: "xmark", help: "Show folder contents") {
                        model.selected = nil
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(node.name)
                    .font(Typo.sectionTitle)
                    .foregroundStyle(Palette.ink(scheme))
                    .lineLimit(2)
                Text(Bytes.format(node.bytes))
                    .font(Typo.metric(26, weight: .bold))
                    .foregroundStyle(Palette.accentGradient)
                Text(Glob.display(node.url.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .lineLimit(3)
            }

            HStack(spacing: 6) {
                Chip(text: node.fileKind, tint: Palette.info)
                if let modified = node.modified {
                    Chip(text: RelativeTime.short(modified), tint: Palette.inkTertiary(scheme))
                }
            }

            VStack(spacing: 7) {
                ApexButton(title: "Reveal in Finder", symbol: "arrow.up.forward.app", kind: .secondary) {
                    model.revealInFinder(node)
                }
                .frame(maxWidth: .infinity)

                if node.hasChildren {
                    ApexButton(title: "Open here", symbol: "arrow.down.forward", kind: .secondary) {
                        model.drill(into: node)
                    }
                    .frame(maxWidth: .infinity)
                }

                ApexButton(
                    title: model.removing.contains(node.id) ? "Moving to Trash" : "Move to Trash",
                    symbol: "trash",
                    kind: .destructive,
                    isLoading: model.removing.contains(node.id)
                ) {
                    model.moveToTrash(node)
                }
                .frame(maxWidth: .infinity)
                .disabled(model.removing.contains(node.id))
            }

            if let error = model.removalError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.caution)
                    Text(error)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(
                "Space Lens can act on personal files, so removals always go to the Trash and never bypass it."
            )
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.inkTertiary(scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var childList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contents").eyebrowStyle(scheme)
            ForEach(model.tiles.prefix(24)) { node in
                Button {
                    model.select(node)
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tileColor(depthIndex(for: node)))
                            .frame(width: 3, height: 16)
                        Text(node.name)
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Bytes.format(node.bytes))
                            .font(Typo.numeric(10.5))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var largeFileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Largest files").eyebrowStyle(scheme)
            ForEach(model.largeFiles.prefix(12)) { match in
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.caution)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(match.url.lastPathComponent)
                            .font(Typo.secondary)
                            .foregroundStyle(Palette.inkSecondary(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(match.displayPath)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Text(Bytes.format(match.bytes))
                        .font(Typo.numeric(10.5))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([match.url])
                    }
                    Button("Move to Trash", role: .destructive) { model.trashLargeFile(match) }
                }
            }
        }
    }
}

/// Palette rotation so adjacent tiles are distinguishable without encoding
/// meaning that does not exist — size is the data, colour is only separation.
func tileColor(_ index: Int) -> Color {
    [
        Palette.jade, Palette.cyan, Color(hex: 0x8B7FF0),
        Color(hex: 0xF5B841), Color(hex: 0xE86FC4), Color(hex: 0x59A5F5),
    ][index % 6]
}

private struct TreemapTile: View {
    let tile: Treemap.Tile
    let isHovered: Bool
    let isSelected: Bool
    let depth: Int

    @Environment(\.colorScheme) private var scheme

    private var color: Color { tileColor(depth) }

    var body: some View {
        let showsLabel = tile.rect.width > 62 && tile.rect.height > 34

        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        color.opacity(isHovered || isSelected ? 0.62 : 0.36),
                        color.opacity(isHovered || isSelected ? 0.36 : 0.18),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isSelected ? color : color.opacity(isHovered ? 0.85 : 0.30),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .overlay(alignment: .topLeading) {
                if showsLabel {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.node.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Palette.ink(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Bytes.format(tile.node.bytes))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Palette.inkSecondary(scheme))
                    }
                    .padding(6)
                    .allowsHitTesting(false)
                }
            }
            .padding(1)
            .shadow(color: color.opacity(isHovered ? 0.4 : 0), radius: 10)
            .animation(Motion.tactile, value: isHovered)
            .animation(Motion.tactile, value: isSelected)
            .help("\(tile.node.name) — \(Bytes.format(tile.node.bytes))")
    }
}
