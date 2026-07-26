import Foundation
import IOKit
import IOKit.ps

public struct PowerVitals: Equatable {
    public var hasBattery: Bool = false
    public var percentage: Int = 100
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    public var cycleCount: Int = 0
    public var designCapacity: Int = 0
    public var currentCapacity: Int = 0
    public var timeRemainingMinutes: Int = -1
    public var temperatureCelsius: Double = 0
    public var condition: String = ""

    /// Maximum capacity as a share of design capacity — the number people mean
    /// when they say "battery health".
    public var healthFraction: Double {
        guard designCapacity > 0 else { return 1 }
        return min(1, Double(currentCapacity) / Double(designCapacity))
    }

    public var timeRemainingLabel: String {
        guard timeRemainingMinutes > 0 else { return isPluggedIn ? "On power adapter" : "Calculating…" }
        let hours = timeRemainingMinutes / 60
        let minutes = timeRemainingMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m left" : "\(minutes)m left"
    }
}

public struct ThermalVitals: Equatable {
    public var state: ProcessInfo.ThermalState = .nominal
    public var label: String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
    /// 0…1 severity, for driving a gauge without exposing a fake temperature.
    public var severity: Double {
        switch state {
        case .nominal: 0.2
        case .fair: 0.45
        case .serious: 0.75
        case .critical: 1.0
        @unknown default: 0.2
        }
    }
}

public enum PowerSampler {
    public static func sample() -> PowerVitals {
        var vitals = PowerVitals()

        // IOPowerSources gives the user-facing summary (percentage, time left).
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        {
            for source in sources {
                guard
                    let description = IOPSGetPowerSourceDescription(blob, source)?
                        .takeUnretainedValue() as? [String: Any]
                else { continue }

                vitals.hasBattery = true
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                    let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
                {
                    vitals.percentage = Int((Double(current) / Double(max)) * 100)
                }
                vitals.isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
                if let state = description[kIOPSPowerSourceStateKey] as? String {
                    vitals.isPluggedIn = state == kIOPSACPowerValue
                }
                if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                    vitals.timeRemainingMinutes = minutes
                }
                if vitals.isCharging, let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0
                {
                    vitals.timeRemainingMinutes = minutes
                }
            }
        }

        // AppleSmartBattery carries the durability figures IOPowerSources omits.
        mergeSmartBattery(into: &vitals)
        return vitals
    }

    private static func mergeSmartBattery(into vitals: inout PowerVitals) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return }

        vitals.hasBattery = true
        vitals.cycleCount = properties["CycleCount"] as? Int ?? vitals.cycleCount

        // Capacity keys, in the order macOS itself trusts them.
        //
        // `MaxCapacity` is deliberately absent. On Apple Silicon it is a
        // *percentage* — this machine reports `MaxCapacity = 100` alongside
        // `DesignCapacity = 5103` — so using it as a mAh figure yields
        // 100/5103 = 2% and flags "Service recommended" on a healthy battery.
        // `NominalChargeCapacity` is what System Settings shows: 4437/5103 =
        // 87%, where `AppleRawMaxCapacity` gives 84% and disagrees visibly with
        // the number the user can check against macOS.
        let design = properties["DesignCapacity"] as? Int ?? 0
        let capacity =
            properties["NominalChargeCapacity"] as? Int
            ?? properties["AppleRawMaxCapacity"] as? Int
            ?? 0
        if design > 0, capacity > 0 {
            vitals.designCapacity = design
            vitals.currentCapacity = min(capacity, design)
        }

        if let raw = properties["Temperature"] as? Int, raw > 0 {
            // Reported in hundredths of a degree on every Mac measured, but
            // some hardware reports whole degrees. Dividing unconditionally
            // would turn 31 °C into 0.31 °C.
            vitals.temperatureCelsius = raw < 1000 ? Double(raw) : Double(raw) / 100.0
        }

        if let condition = properties["PermanentFailureStatus"] as? Int, condition != 0 {
            vitals.condition = "Service recommended"
        } else if vitals.cycleCount > 1000 || vitals.healthFraction < 0.8 {
            vitals.condition = "Service recommended"
        } else {
            vitals.condition = "Normal"
        }
    }
}

public enum ThermalSampler {
    public static func sample() -> ThermalVitals {
        ThermalVitals(state: ProcessInfo.processInfo.thermalState)
    }
}
