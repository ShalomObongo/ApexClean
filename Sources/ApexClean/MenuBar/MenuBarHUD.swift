import ApexCore
import SwiftUI

/// The menu bar HUD.
///
/// Deliberately quiet: it reports condition, it does not nag. There are no
/// recommendations, no badges that demand attention, and no "your Mac needs
/// cleaning" prompts. Opening the popover is what starts live sampling.
struct MenuBarHUD: View {
    @EnvironmentObject private var state: AppState
    /// Observed directly. Reaching the monitor through `state.vitals` would
    /// subscribe this view to `AppState` only, and the readouts would freeze at
    /// whatever they held when the popover first opened.
    @ObservedObject var vitals: VitalsMonitor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    @State private var expanded: String?
    @AppStorage("showsMenuBarHUD") private var showsMenuBarHUD = false

    private var snapshot: VitalsMonitor.Snapshot { vitals.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            headline
            Divider().overlay(Palette.hairline(scheme))
            tiles
            Divider().overlay(Palette.hairline(scheme))
            footer
        }
        .frame(width: 320)
        .background(Palette.canvas(scheme))
        .onAppear { vitals.addSubscriber() }
        .onDisappear { vitals.removeSubscriber() }
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(spacing: 12) {
            ZStack {
                RingGauge(
                    value: Double(snapshot.health.value) / 100,
                    tint: Palette.health(snapshot.health.value),
                    thickness: 4
                )
                .frame(width: 42, height: 42)
                Text("\(snapshot.health.value)")
                    .font(Typo.metric(15, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))
                    .contentTransition(.numericText())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.health.band.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink(scheme))
                Text(headlineDetail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var headlineDetail: String {
        if let worst = snapshot.health.significantFactors.first {
            return "\(worst.name.lowercased()) · \(worst.detail)"
        }
        return "Up \(RelativeTime.duration(snapshot.uptime)) · nothing needs attention"
    }

    // MARK: - Tiles

    private var tiles: some View {
        VStack(spacing: 0) {
            metricRow(
                id: "cpu",
                symbol: "cpu",
                title: "Processor",
                value: String(format: "%.0f%%", snapshot.cpu.usage),
                fraction: snapshot.cpu.usage / 100,
                history: vitals.cpuHistory
            ) {
                ForEach(snapshot.topCPU.prefix(4)) { process in
                    subRow(process.name, String(format: "%.1f%%", process.cpuPercent))
                }
            }

            metricRow(
                id: "memory",
                symbol: "memorychip",
                title: "Memory",
                value: "\(Bytes.format(snapshot.memory.used))",
                fraction: snapshot.memory.pressure,
                history: vitals.memoryHistory
            ) {
                subRow("Pressure", snapshot.memory.pressureLabel)
                subRow("Wired", Bytes.format(snapshot.memory.wired))
                subRow("Compressed", Bytes.format(snapshot.memory.compressed))
                if snapshot.memory.swapUsed > 0 {
                    subRow("Swap", Bytes.format(snapshot.memory.swapUsed))
                }
            }

            metricRow(
                id: "storage",
                symbol: "internaldrive",
                title: "Storage",
                value: Bytes.format(snapshot.storage.free),
                fraction: snapshot.storage.usedFraction,
                history: nil
            ) {
                subRow("Used", Bytes.format(snapshot.storage.used))
                subRow("Capacity", Bytes.format(snapshot.storage.total))
                if snapshot.storage.purgeable > 0 {
                    subRow("Purgeable", Bytes.format(snapshot.storage.purgeable))
                }
            }

            metricRow(
                id: "network",
                symbol: "arrow.up.arrow.down",
                title: "Network",
                value: "\(Bytes.format(Int64(snapshot.network.downloadBytesPerSecond)))/s",
                fraction: nil,
                history: vitals.downloadHistory
            ) {
                subRow("Downloaded", Bytes.format(snapshot.network.totalReceived))
                subRow("Uploaded", Bytes.format(snapshot.network.totalSent))
                subRow("Interface", snapshot.network.interface.isEmpty ? "—" : snapshot.network.interface)
            }

            if snapshot.power.hasBattery {
                metricRow(
                    id: "battery",
                    symbol: snapshot.power.isCharging ? "battery.100.bolt" : "battery.75",
                    title: "Battery",
                    value: "\(snapshot.power.percentage)%",
                    fraction: 1 - Double(snapshot.power.percentage) / 100,
                    history: nil
                ) {
                    subRow("Health", "\(Int(snapshot.power.healthFraction * 100))%")
                    subRow("Cycles", "\(snapshot.power.cycleCount)")
                    subRow("Condition", snapshot.power.condition)
                    subRow("Status", snapshot.power.timeRemainingLabel)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func metricRow<Detail: View>(
        id: String,
        symbol: String,
        title: String,
        value: String,
        fraction: Double?,
        history: [Double]?,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        let isExpanded = expanded == id
        let tint = fraction.map { Palette.load($0) } ?? Palette.info

        VStack(spacing: 0) {
            Button {
                withAnimation(Motion.tactile) { expanded = isExpanded ? nil : id }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 18)

                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink(scheme))

                    Spacer(minLength: 6)

                    if let history, history.count > 2 {
                        Sparkline(
                            values: history,
                            tint: tint,
                            ceiling: fraction != nil ? 1 : nil,
                            lineWidth: 1.2,
                            showsFill: false
                        )
                        .frame(width: 52, height: 15)
                    }

                    Text(value)
                        .font(Typo.numeric(12, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .contentTransition(.numericText())

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 3) {
                    detail()
                }
                .padding(.horizontal, 14)
                .padding(.leading, 28)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .background(
            Color.primary.opacity(isExpanded ? 0.035 : 0)
        )
    }

    private func subRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkTertiary(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .font(Typo.numeric(10.5))
                .foregroundStyle(Palette.inkSecondary(scheme))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openMainWindow(.smartCare)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .bold))
                    Text("Open ApexClean").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.action)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Palette.contour(scheme), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button {
                openMainWindow(.vitals)
            } label: {
                Text("Vitals")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Toggle("Show in menu bar", isOn: $showsMenuBarHUD)
                Divider()
                Button("Quit ApexClean") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func openMainWindow(_ destination: Destination) {
        state.destination = destination
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

/// The status item itself. A ring whose colour tracks health — legible at 16pt,
/// and never a red alert badge that manufactures urgency.
struct MenuBarLabel: View {
    @ObservedObject var vitals: VitalsMonitor

    var body: some View {
        let health = vitals.snapshot.health.value
        Image(systemName: symbol(for: health))
            .foregroundStyle(Palette.health(health))
    }

    private func symbol(for health: Int) -> String {
        switch health {
        case 85...: "circle.hexagongrid.fill"
        case 65..<85: "circle.hexagongrid"
        default: "circle.hexagongrid.circle"
        }
    }
}
