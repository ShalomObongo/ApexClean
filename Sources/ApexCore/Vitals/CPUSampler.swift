import Darwin
import Foundation

public struct CPUVitals: Equatable {
    public var usage: Double = 0
    public var user: Double = 0
    public var system: Double = 0
    public var idle: Double = 100
    public var coreUsage: [Double] = []
    public var loadAverage: (Double, Double, Double) = (0, 0, 0)
    public var physicalCores: Int = 0
    public var logicalCores: Int = 0

    public static func == (lhs: CPUVitals, rhs: CPUVitals) -> Bool {
        lhs.usage == rhs.usage && lhs.coreUsage == rhs.coreUsage
    }
}

/// Samples per-core tick counters and converts consecutive samples into a usage
/// percentage. Requires two samples, so the first reading is reported as idle.
public final class CPUSampler {
    private var previousTicks: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []

    public init() {}

    public func sample() -> CPUVitals {
        var vitals = CPUVitals()
        vitals.logicalCores = ProcessInfo.processInfo.processorCount
        vitals.physicalCores = Self.physicalCoreCount()
        vitals.loadAverage = Self.loadAverage()

        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return vitals }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        current.reserveCapacity(Int(cpuCount))
        for index in 0..<Int(cpuCount) {
            let base = index * Int(CPU_STATE_MAX)
            current.append(
                (
                    user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
                )
            )
        }

        defer { previousTicks = current }
        guard previousTicks.count == current.count, !previousTicks.isEmpty else { return vitals }

        var totalUser = 0.0
        var totalSystem = 0.0
        var totalIdle = 0.0
        var totalAll = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for index in 0..<current.count {
            let now = current[index]
            let before = previousTicks[index]
            let user = Double(now.user &- before.user)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)
            let nice = Double(now.nice &- before.nice)
            let total = user + system + idle + nice

            totalUser += user
            totalSystem += system
            totalIdle += idle
            totalAll += total

            perCore.append(total > 0 ? ((total - idle) / total) * 100 : 0)
        }

        guard totalAll > 0 else { return vitals }
        vitals.user = (totalUser / totalAll) * 100
        vitals.system = (totalSystem / totalAll) * 100
        vitals.idle = (totalIdle / totalAll) * 100
        vitals.usage = max(0, min(100, 100 - vitals.idle))
        vitals.coreUsage = perCore
        return vitals
    }

    static func physicalCoreCount() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &value, &size, nil, 0) == 0 { return Int(value) }
        return ProcessInfo.processInfo.processorCount
    }

    static func loadAverage() -> (Double, Double, Double) {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return (0, 0, 0) }
        return (averages[0], averages[1], averages[2])
    }
}
