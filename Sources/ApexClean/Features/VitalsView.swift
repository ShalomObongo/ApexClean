import ApexCore
import SwiftUI

struct VitalsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    /// Observed directly — see the note in ApplicationsView. Vitals publishes
    /// on every sample tick, and this screen is the only one that needs it.
    @ObservedObject var monitor: VitalsMonitor

    private var vitals: VitalsMonitor { monitor }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                healthCard
                // Two fixed columns rather than `.adaptive`: adaptive sizing
                // re-measures every child to decide the column count, and this
                // grid rebuilds on every two-second sample. The window cannot
                // go narrower than 1040pt, which always leaves each column
                // above the 300pt these cards are designed for, so the count
                // was never actually in question.
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14),
                    ],
                    spacing: 14
                ) {
                    cpuCard
                    memoryCard
                    storageCard
                    networkCard
                    if vitals.snapshot.power.hasBattery { powerCard }
                    thermalCard
                }
                processCard
            }
            .padding(28)
            .frame(maxWidth: 1_000)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        PageHeader(
            eyebrow: "Vitals",
            title: "Live system condition",
            subtitle: "Sampled every two seconds from the kernel. Nothing here is uploaded or recorded."
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Uptime").eyebrowStyle(scheme)
                Text(RelativeTime.duration(vitals.snapshot.uptime))
                    .font(Typo.metric(15, weight: .semibold))
                    .foregroundStyle(Palette.ink(scheme))
            }
        }
    }

    // MARK: - Health

    private var healthCard: some View {
        let health = vitals.snapshot.health
        return ApexCard(padding: 20) {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 8) {
                    ZStack {
                        RingGauge(
                            value: Double(health.value) / 100,
                            tint: Palette.health(health.value),
                            thickness: 9
                        )
                        .frame(width: 106, height: 106)
                        VStack(spacing: -2) {
                            Text("\(health.value)")
                                .font(Typo.metric(38, weight: .bold))
                                .foregroundStyle(Palette.ink(scheme))
                                .contentTransition(.numericText())
                            Text("of 100")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.inkTertiary(scheme))
                        }
                    }
                    Text(health.band.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.health(health.value))
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Every point is accounted for").eyebrowStyle(scheme)
                    if health.significantFactors.isEmpty {
                        Text(
                            "Nothing is currently costing your Mac points. This score is a summary of load, not a reason to clean anything."
                        )
                        .font(Typo.body)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(health.significantFactors) { factor in
                            HStack(spacing: 10) {
                                Text("−\(Int(factor.deduction.rounded()))")
                                    .font(Typo.numeric(12, weight: .bold))
                                    .foregroundStyle(Palette.caution)
                                    .frame(width: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(factor.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Palette.ink(scheme))
                                    Text(factor.detail)
                                        .font(Typo.caption)
                                        .foregroundStyle(Palette.inkTertiary(scheme))
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Metric cards

    private var cpuCard: some View {
        let cpu = vitals.snapshot.cpu
        return MetricCard(
            title: "Processor",
            symbol: "cpu",
            tint: Palette.load(cpu.usage / 100),
            value: String(format: "%.0f%%", cpu.usage),
            caption:
                "\(cpu.physicalCores)P/\(cpu.logicalCores)L cores · load \(String(format: "%.2f", cpu.loadAverage.0))"
        ) {
            VStack(spacing: 9) {
                Sparkline(values: vitals.cpuHistory, tint: Palette.load(cpu.usage / 100), ceiling: 1)
                    .frame(height: 44)

                if !cpu.coreUsage.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(cpu.coreUsage.enumerated()), id: \.offset) { _, usage in
                            GeometryReader { geometry in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Palette.load(usage / 100))
                                        .frame(height: max(2, geometry.size.height * usage / 100))
                                }
                            }
                            .frame(height: 20)
                        }
                    }
                    .animation(Motion.stream, value: cpu.coreUsage)
                }
            }
        }
    }

    private var memoryCard: some View {
        let memory = vitals.snapshot.memory
        return MetricCard(
            title: "Memory",
            symbol: "memorychip",
            tint: Palette.load(memory.pressure),
            value: Bytes.format(memory.used),
            caption: "of \(Bytes.format(memory.total)) · pressure \(memory.pressureLabel.lowercased())"
        ) {
            VStack(spacing: 9) {
                Sparkline(values: vitals.memoryHistory, tint: Palette.load(memory.pressure), ceiling: 1)
                    .frame(height: 44)
                VStack(spacing: 4) {
                    detailRow("Wired", Bytes.format(memory.wired))
                    detailRow("Compressed", Bytes.format(memory.compressed))
                    detailRow("Cached files", Bytes.format(memory.cached))
                    if memory.swapUsed > 0 {
                        detailRow("Swap in use", Bytes.format(memory.swapUsed), tint: Palette.caution)
                    }
                }
            }
        }
    }

    private var storageCard: some View {
        let storage = vitals.snapshot.storage
        return MetricCard(
            title: "Storage",
            symbol: "internaldrive",
            tint: Palette.load(storage.usedFraction),
            value: Bytes.format(storage.free),
            caption: "free of \(Bytes.format(storage.total)) on \(storage.name)"
        ) {
            VStack(spacing: 9) {
                CapacityBar(
                    used: storage.used,
                    total: storage.total,
                    height: 9,
                    tint: Palette.load(storage.usedFraction)
                )
                VStack(spacing: 4) {
                    detailRow("Used", Bytes.format(storage.used))
                    if storage.purgeable > 0 {
                        detailRow("Purgeable by macOS", Bytes.format(storage.purgeable))
                    }
                    detailRow(
                        "Reclaimable by ApexClean",
                        state.cleanup.report.totalBytes > 0
                            ? Bytes.format(state.cleanup.report.totalBytes)
                            : "run a scan")
                }
            }
        }
    }

    private var networkCard: some View {
        let network = vitals.snapshot.network
        return MetricCard(
            title: "Network",
            symbol: "arrow.up.arrow.down",
            tint: Palette.info,
            value: "\(Bytes.format(Int64(network.downloadBytesPerSecond)))/s",
            caption: network.interface.isEmpty ? "no active interface" : "down on \(network.interface)"
        ) {
            VStack(spacing: 7) {
                Sparkline(values: vitals.downloadHistory, tint: Palette.info)
                    .frame(height: 30)
                Sparkline(values: vitals.uploadHistory, tint: Palette.jade)
                    .frame(height: 30)
                HStack {
                    Label(Bytes.format(network.totalReceived), systemImage: "arrow.down")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.info)
                    Spacer()
                    Label(Bytes.format(network.totalSent), systemImage: "arrow.up")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.jade)
                }
            }
        }
    }

    private var powerCard: some View {
        let power = vitals.snapshot.power
        return MetricCard(
            title: "Battery",
            symbol: power.isCharging ? "battery.100.bolt" : "battery.75",
            tint: power.percentage < 20 ? Palette.alert : Palette.jade,
            value: "\(power.percentage)%",
            caption: power.timeRemainingLabel
        ) {
            VStack(spacing: 9) {
                CapacityBar(
                    used: Int64(power.percentage),
                    total: 100,
                    height: 9,
                    tint: power.percentage < 20 ? Palette.alert : Palette.jade
                )
                VStack(spacing: 4) {
                    detailRow("Maximum capacity", "\(Int(power.healthFraction * 100))%")
                    detailRow("Cycle count", "\(power.cycleCount)")
                    detailRow(
                        "Condition", power.condition,
                        tint: power.condition == "Normal" ? nil : Palette.caution)
                    if power.temperatureCelsius > 0 {
                        detailRow("Temperature", String(format: "%.1f °C", power.temperatureCelsius))
                    }
                }
            }
        }
    }

    private var thermalCard: some View {
        let thermal = vitals.snapshot.thermal
        return MetricCard(
            title: "Thermal",
            symbol: "thermometer.medium",
            tint: Palette.load(thermal.severity),
            value: thermal.label,
            caption: "as reported by macOS"
        ) {
            VStack(alignment: .leading, spacing: 9) {
                CapacityBar(
                    used: Int64(thermal.severity * 100),
                    total: 100,
                    height: 9,
                    tint: Palette.load(thermal.severity)
                )
                Text(thermalExplanation)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var thermalExplanation: String {
        switch vitals.snapshot.thermal.state {
        case .nominal: "No thermal limiting. Fans and clocks are unconstrained."
        case .fair: "Mild thermal management. Performance is essentially unaffected."
        case .serious: "macOS is throttling to manage heat. Heavy work will run slower."
        case .critical: "Aggressive throttling. Consider reducing load or improving airflow."
        @unknown default: "State unknown."
        }
    }

    private var processCard: some View {
        ApexCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    eyebrow: "Activity",
                    title: "What's using your Mac",
                    subtitle: "Read-only. ApexClean does not quit processes on your behalf."
                )
                HStack(alignment: .top, spacing: 22) {
                    processColumn("By processor", vitals.snapshot.topCPU) { process in
                        (String(format: "%.1f%%", process.cpuPercent), min(1, process.cpuPercent / 100))
                    }
                    Divider().frame(height: 150).overlay(Palette.hairline(scheme))
                    processColumn("By memory", vitals.snapshot.topMemory) { process in
                        (
                            Bytes.format(process.memoryBytes),
                            min(1, Double(process.memoryBytes) / Double(max(1, vitals.snapshot.memory.total)))
                        )
                    }
                }
            }
        }
    }

    private func processColumn(
        _ title: String,
        _ processes: [ProcessVitals],
        metric: @escaping (ProcessVitals) -> (String, Double)
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).eyebrowStyle(scheme)
            ForEach(processes.prefix(6)) { process in
                let (label, fraction) = metric(process)
                HStack(spacing: 8) {
                    Text(process.name)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.hairline(scheme))
                            Capsule()
                                .fill(Palette.load(fraction))
                                .frame(width: max(2, geometry.size.width * fraction))
                        }
                    }
                    .frame(width: 46, height: 4)
                    Text(label)
                        .font(Typo.numeric(10.5))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(Palette.inkTertiary(scheme))
            Spacer()
            Text(value)
                .font(Typo.numeric(11, weight: .medium))
                .foregroundStyle(tint ?? Palette.inkSecondary(scheme))
        }
    }
}

struct MetricCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let caption: String
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ApexCard(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    GlyphTile(symbol: symbol, tint: tint, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                        Text(value)
                            .font(Typo.metric(21, weight: .bold))
                            .foregroundStyle(Palette.ink(scheme))
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                }
                Text(caption)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .lineLimit(1)

                content()
            }
        }
    }
}
