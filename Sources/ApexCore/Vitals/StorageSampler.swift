import Foundation
import Darwin

public struct StorageVitals: Equatable {
    public var name: String = "Macintosh HD"
    public var total: Int64 = 0
    public var free: Int64 = 0
    public var used: Int64 = 0
    /// Space macOS can reclaim on demand (snapshots, purgeable caches).
    public var purgeable: Int64 = 0

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct NetworkVitals: Equatable {
    public var downloadBytesPerSecond: Double = 0
    public var uploadBytesPerSecond: Double = 0
    public var totalReceived: Int64 = 0
    public var totalSent: Int64 = 0
    public var interface: String = ""
}

public enum StorageSampler {
    public static func sample() -> StorageVitals {
        var vitals = StorageVitals()
        let url = URL(fileURLWithPath: "/")

        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeNameKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return vitals }

        vitals.name = values.volumeName ?? "Macintosh HD"
        vitals.total = Int64(values.volumeTotalCapacity ?? 0)

        // `forImportantUsage` includes space macOS would purge to satisfy a
        // request — the honest answer to "how much can I actually use?".
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let strict = Int64(values.volumeAvailableCapacity ?? 0)
        vitals.free = max(strict, Int64(important))
        vitals.purgeable = max(0, vitals.free - strict)
        vitals.used = max(0, vitals.total - vitals.free)
        return vitals
    }

    public static func allVolumes() -> [StorageVitals] {
        let keys: [URLResourceKey] = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeNameKey,
            .volumeIsBrowsableKey,
            .volumeIsLocalKey,
        ]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [sample()] }

        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  values.volumeIsLocal == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            var vitals = StorageVitals()
            vitals.name = values.volumeName ?? url.lastPathComponent
            vitals.total = Int64(total)
            let strict = Int64(values.volumeAvailableCapacity ?? 0)
            vitals.free = max(strict, Int64(values.volumeAvailableCapacityForImportantUsage ?? 0))
            vitals.purgeable = max(0, vitals.free - strict)
            vitals.used = max(0, vitals.total - vitals.free)
            return vitals
        }
    }
}

/// Reads cumulative interface counters and differentiates them into a rate.
public final class NetworkSampler {
    private var lastReceived: Int64 = 0
    private var lastSent: Int64 = 0
    private var lastSampleTime: Date?

    public init() {}

    public func sample() -> NetworkVitals {
        var vitals = NetworkVitals()
        let totals = Self.interfaceTotals()
        vitals.totalReceived = totals.received
        vitals.totalSent = totals.sent
        vitals.interface = totals.primary

        let now = Date()
        defer {
            lastReceived = totals.received
            lastSent = totals.sent
            lastSampleTime = now
        }

        guard let last = lastSampleTime else { return vitals }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0.05 else { return vitals }

        // Counters reset when an interface cycles; clamp instead of reporting a
        // nonsensical negative rate.
        vitals.downloadBytesPerSecond = max(0, Double(totals.received - lastReceived) / elapsed)
        vitals.uploadBytesPerSecond = max(0, Double(totals.sent - lastSent) / elapsed)
        return vitals
    }

    private static func interfaceTotals() -> (received: Int64, sent: Int64, primary: String) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0, "") }
        defer { freeifaddrs(addresses) }

        var received: Int64 = 0
        var sent: Int64 = 0
        var primary = ""
        var busiest: Int64 = 0

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            // Loopback and virtual interfaces would double-count local traffic.
            guard !name.hasPrefix("lo"), !name.hasPrefix("gif"), !name.hasPrefix("stf"),
                  !name.hasPrefix("bridge"), !name.hasPrefix("utun"), !name.hasPrefix("awdl")
            else { continue }

            guard let dataPointer = current.pointee.ifa_data else { continue }
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            let inBytes = Int64(data.ifi_ibytes)
            let outBytes = Int64(data.ifi_obytes)
            received += inBytes
            sent += outBytes

            if inBytes + outBytes > busiest {
                busiest = inBytes + outBytes
                primary = name
            }
        }

        return (received, sent, primary)
    }
}
