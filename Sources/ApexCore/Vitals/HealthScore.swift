import Foundation

/// A single, honest summary of system condition.
///
/// The score is deliberately conservative and always explains itself: every
/// point deducted is attributable to a named, observable factor. It never
/// invents urgency to justify running a cleanup.
public struct HealthScore: Equatable {
    public struct Factor: Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var deduction: Double
        public var detail: String
    }

    public var value: Int = 100
    public var factors: [Factor] = []

    public var band: Band {
        switch value {
        case 85...: .excellent
        case 65..<85: .good
        case 45..<65: .fair
        default: .needsAttention
        }
    }

    public enum Band: String {
        case excellent = "Excellent"
        case good = "Good"
        case fair = "Fair"
        case needsAttention = "Needs attention"
    }

    /// Factors that actually cost points, worst first.
    public var significantFactors: [Factor] {
        factors.filter { $0.deduction >= 1 }.sorted { $0.deduction > $1.deduction }
    }
}

public enum HealthEvaluator {
    // Weights sum to 100. CPU and memory dominate because they are what a user
    // actually feels; storage matters most as it approaches full.
    private static let cpuWeight = 26.0
    private static let memoryWeight = 24.0
    private static let storageWeight = 22.0
    private static let thermalWeight = 14.0
    private static let batteryWeight = 8.0
    private static let uptimeWeight = 6.0

    public static func evaluate(
        cpu: CPUVitals,
        memory: MemoryVitals,
        storage: StorageVitals,
        thermal: ThermalVitals,
        power: PowerVitals,
        uptime: TimeInterval
    ) -> HealthScore {
        var score = HealthScore()
        var total = 100.0

        // CPU: sustained load only starts costing points above half capacity.
        var cpuDeduction = 0.0
        if cpu.usage > 50 {
            cpuDeduction = cpuWeight * ((cpu.usage - 50) / 50)
        }
        cpuDeduction = min(cpuWeight, cpuDeduction)
        score.factors.append(
            .init(
                name: "Processor load",
                deduction: cpuDeduction,
                detail: String(format: "%.0f%% in use across %d cores", cpu.usage, max(1, cpu.logicalCores))
            )
        )

        // Memory: pressure is a better signal than raw usage, because macOS is
        // supposed to use all available memory.
        var memoryDeduction = 0.0
        if memory.pressure > 0.55 {
            memoryDeduction = memoryWeight * ((memory.pressure - 0.55) / 0.45)
        }
        if memory.swapUsed > 2_147_483_648 { memoryDeduction += 4 }
        memoryDeduction = min(memoryWeight, memoryDeduction)
        score.factors.append(
            .init(
                name: "Memory pressure",
                deduction: memoryDeduction,
                detail:
                    "\(memory.pressureLabel) · \(Bytes.format(memory.used)) of \(Bytes.format(memory.total)) used"
            )
        )

        // Storage: only meaningful once the volume is genuinely tight.
        let usedPercent = storage.usedFraction * 100
        var storageDeduction = 0.0
        if usedPercent > 80 {
            storageDeduction = storageWeight * ((usedPercent - 80) / 20)
        }
        storageDeduction = min(storageWeight, storageDeduction)
        score.factors.append(
            .init(
                name: "Available storage",
                deduction: storageDeduction,
                detail: "\(Bytes.format(storage.free)) free of \(Bytes.format(storage.total))"
            )
        )

        var thermalDeduction = 0.0
        switch thermal.state {
        case .nominal: thermalDeduction = 0
        case .fair: thermalDeduction = thermalWeight * 0.25
        case .serious: thermalDeduction = thermalWeight * 0.7
        case .critical: thermalDeduction = thermalWeight
        @unknown default: thermalDeduction = 0
        }
        score.factors.append(
            .init(name: "Thermal state", deduction: thermalDeduction, detail: thermal.label)
        )

        var batteryDeduction = 0.0
        if power.hasBattery {
            let health = power.healthFraction
            if health < 0.85 {
                batteryDeduction = batteryWeight * min(1, (0.85 - health) / 0.25)
            }
            if power.cycleCount > 1000 { batteryDeduction = max(batteryDeduction, batteryWeight * 0.6) }
            score.factors.append(
                .init(
                    name: "Battery condition",
                    deduction: min(batteryWeight, batteryDeduction),
                    detail: "\(Int(health * 100))% capacity · \(power.cycleCount) cycles"
                )
            )
        }

        // Uptime: a long-running Mac accumulates state that a restart clears.
        let days = uptime / 86_400
        var uptimeDeduction = 0.0
        if days > 7 { uptimeDeduction = min(uptimeWeight, uptimeWeight * ((days - 7) / 14)) }
        score.factors.append(
            .init(
                name: "Time since restart",
                deduction: uptimeDeduction,
                detail: RelativeTime.duration(uptime)
            )
        )

        total -= score.factors.reduce(0) { $0 + $1.deduction }
        score.value = Int(max(0, min(100, total.rounded())))
        return score
    }

    public static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }
}
