import Darwin
import Foundation

public struct MemoryVitals: Equatable, Sendable {
    public var total: Int64 = 0
    public var used: Int64 = 0
    public var active: Int64 = 0
    public var wired: Int64 = 0
    public var compressed: Int64 = 0
    public var cached: Int64 = 0
    public var free: Int64 = 0
    public var swapUsed: Int64 = 0
    public var swapTotal: Int64 = 0
    /// macOS's own verdict, not a derived one. See `MemoryPressureLevel`.
    public var pressureLevel: MemoryPressureLevel = .normal
    /// 0…1, for the graph. Anchored to `pressureLevel` so the curve, the label
    /// and the health score can never disagree with the kernel or each other.
    public var pressure: Double = 0

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public var pressureLabel: String { pressureLevel.label }
}

/// The kernel's memory pressure state, read rather than inferred.
///
/// ApexClean used to compute this itself as `(wired + compressed) / total`,
/// plus a swap term. On Apple Silicon wired memory alone sits at a fifth of RAM
/// when the machine is doing nothing, so that expression started around 0.3 and
/// reached "Critical" on a Mac the kernel considered merely warm — measured at
/// 0.90 against a kernel reporting `warn` and 40% of memory free. Compressed
/// memory is a sign the system is *coping*, not failing, and counting it as
/// unreclaimable pressure punishes the mechanism that prevents the problem.
public enum MemoryPressureLevel: Int, Sendable, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

public enum MemorySampler {
    public static func sample() -> MemoryVitals {
        var vitals = MemoryVitals()
        vitals.total = Int64(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return vitals }

        var rawPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS else { return vitals }
        let pageSize = Int64(rawPageSize)
        vitals.active = Int64(stats.active_count) * pageSize
        vitals.wired = Int64(stats.wire_count) * pageSize
        vitals.compressed = Int64(stats.compressor_page_count) * pageSize
        vitals.cached = Int64(stats.external_page_count) * pageSize
        vitals.free = Int64(stats.free_count) * pageSize

        // Activity Monitor's "Memory Used" = app memory + wired + compressed,
        // where app memory is anonymous minus purgeable. The previous version
        // added `active` to `internal_page_count`, which double-counts every
        // active anonymous page, and then subtracted compressed memory as if
        // that cancelled it out. Measured against Activity Monitor on this
        // machine the result was 5.68 GiB against a true 6.35 GiB, and the sign
        // of the error follows compressor occupancy — so it over-reports just
        // as readily as it under-reports.
        // Widened before subtracting: both counts are `natural_t`, so doing the
        // arithmetic at 32 bits would trap the whole app rather than return a
        // negative number if purgeable ever exceeded anonymous.
        let anonymous = Int64(stats.internal_page_count)
        let purgeable = Int64(stats.purgeable_count)
        let appMemory = max(0, (anonymous - purgeable) * pageSize)
        vitals.used = min(vitals.total, appMemory + vitals.wired + vitals.compressed)

        let swap = swapUsage()
        vitals.swapUsed = swap.used
        vitals.swapTotal = swap.total

        vitals.pressureLevel = pressureLevel()
        // Position within the level's band, so the graph still moves while the
        // band itself stays the kernel's call.
        let within = min(1, max(0, vitals.usedFraction))
        // Bands are contiguous: 0–0.50 normal, 0.50–0.80 warning, 0.80–1.0
        // critical. An earlier version started the warning band at 0.55, which
        // left two ranges the value could never take and made the low end of
        // "warning" indistinguishable from "normal" to the health score.
        switch vitals.pressureLevel {
        case .normal: vitals.pressure = 0.50 * within
        case .warning: vitals.pressure = 0.50 + 0.30 * within
        case .critical: vitals.pressure = 0.80 + 0.20 * within
        }

        return vitals
    }

    /// Reads `kern.memorystatus_vm_pressure_level`, the same signal
    /// `memory_pressure(1)` reports and the one macOS acts on itself.
    private static func pressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard
            sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
            let parsed = MemoryPressureLevel(rawValue: Int(level))
        else { return .normal }
        return parsed
    }

    private static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }
}
