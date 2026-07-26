import Foundation
import Darwin

public struct MemoryVitals: Equatable {
    public var total: Int64 = 0
    public var used: Int64 = 0
    public var active: Int64 = 0
    public var wired: Int64 = 0
    public var compressed: Int64 = 0
    public var cached: Int64 = 0
    public var free: Int64 = 0
    public var swapUsed: Int64 = 0
    public var swapTotal: Int64 = 0
    /// 0…1. Mirrors what Activity Monitor calls memory pressure: the share of
    /// memory that cannot be reclaimed without swapping.
    public var pressure: Double = 0

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public var pressureLabel: String {
        switch pressure {
        case ..<0.55: "Normal"
        case ..<0.80: "Elevated"
        default: "Critical"
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

        let pageSize = Int64(vm_kernel_page_size)
        vitals.active = Int64(stats.active_count) * pageSize
        vitals.wired = Int64(stats.wire_count) * pageSize
        vitals.compressed = Int64(stats.compressor_page_count) * pageSize
        vitals.cached = Int64(stats.external_page_count) * pageSize
        vitals.free = Int64(stats.free_count) * pageSize

        // Activity Monitor's "Memory Used" = app memory + wired + compressed.
        let appMemory = max(0, vitals.active + Int64(stats.internal_page_count) * pageSize - vitals.compressed)
        vitals.used = min(vitals.total, appMemory + vitals.wired + vitals.compressed)

        let swap = swapUsage()
        vitals.swapUsed = swap.used
        vitals.swapTotal = swap.total

        // Unreclaimable share: wired and compressed pages cannot be evicted, and
        // active swap is direct evidence the system is already under strain.
        let unreclaimable = Double(vitals.wired + vitals.compressed)
        let base = Double(max(vitals.total, 1))
        var pressure = unreclaimable / base
        if vitals.swapUsed > 0 {
            pressure += min(0.35, Double(vitals.swapUsed) / base)
        }
        vitals.pressure = min(1, max(0, pressure))

        return vitals
    }

    private static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }
}
