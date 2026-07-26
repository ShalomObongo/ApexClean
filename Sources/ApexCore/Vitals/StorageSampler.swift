import Darwin
import Foundation

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
        guard
            let volumes = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]
            )
        else { return [sample()] }

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
///
/// The counters macOS hands out through `getifaddrs` are **32-bit**, even
/// though the `if_data64` shape suggests otherwise: measured against
/// `netstat -ibdn` on a live machine, the sysctl figure was short by exactly
/// 7 x 2^32 on one direction and 10 x 2^32 on the other. Reading them as
/// absolute totals under-reports by whole multiples of 4 GiB, and naively
/// subtracting successive samples makes the rate collapse to zero every time
/// one rolls over.
///
/// So counters are treated as what they are — a 32-bit odometer. Deltas are
/// computed per interface with wraparound arithmetic, which keeps the live rate
/// correct through every roll, and the true 64-bit starting totals are read
/// once from `netstat` and advanced by those same deltas. That costs a single
/// subprocess for the lifetime of the app rather than one per sample.
public final class NetworkSampler {
    private struct Counters {
        var received: UInt32 = 0
        var sent: UInt32 = 0
    }

    private var lastRaw: [String: Counters] = [:]
    private var lastSampleTime: Date?
    private var totalReceived: Int64 = 0
    private var totalSent: Int64 = 0
    private var hasSeededTotals = false

    /// Interfaces whose traffic is either local or a duplicate of another
    /// interface's. `ap` is the Wi-Fi hotspot shadow of `en0`, so counting it
    /// would add the same packets twice while Internet Sharing is on.
    private static let ignoredPrefixes = [
        "lo", "gif", "stf", "bridge", "utun", "awdl", "llw", "anpi", "xhc", "ap",
    ]

    /// The most traffic a delta may claim before it is read as a counter reset
    /// rather than a rollover. 20 Gbit/s clears any Ethernet or Thunderbolt
    /// link a Mac can present; beyond that the interface almost certainly
    /// restarted, and inventing the difference would spike the graph.
    private static let plausibleBytesPerSecond: Double = 2.5e9

    public init() {}

    public func sample() -> NetworkVitals {
        var vitals = NetworkVitals()
        let raw = Self.rawCounters()
        let now = Date()
        let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? 0

        if !hasSeededTotals {
            let seed = Self.seedTotals()
            totalReceived = seed.received
            totalSent = seed.sent
            hasSeededTotals = true
        }

        var receivedDelta: Int64 = 0
        var sentDelta: Int64 = 0
        var busiest: UInt32 = 0

        for (name, counters) in raw {
            if let previous = lastRaw[name] {
                let budget = elapsed > 0 ? elapsed * Self.plausibleBytesPerSecond : .infinity
                receivedDelta += Self.delta(previous.received, counters.received, budget: budget)
                sentDelta += Self.delta(previous.sent, counters.sent, budget: budget)
            }
            // An interface seen for the first time contributes no delta: its
            // counter already holds history this process never observed.
            let busyness = counters.received &+ counters.sent
            if busyness > busiest {
                busiest = busyness
                vitals.interface = name
            }
        }

        lastRaw = raw
        lastSampleTime = now
        totalReceived += receivedDelta
        totalSent += sentDelta
        vitals.totalReceived = totalReceived
        vitals.totalSent = totalSent

        guard elapsed > 0.05 else { return vitals }
        vitals.downloadBytesPerSecond = Double(receivedDelta) / elapsed
        vitals.uploadBytesPerSecond = Double(sentDelta) / elapsed
        return vitals
    }

    /// Advances a 32-bit odometer, tolerating the roll from `UInt32.max` to 0.
    ///
    /// A decrease is normally a rollover, so the wrapped difference is the
    /// honest answer. It can also mean the interface reset to zero, and the two
    /// are indistinguishable from the counter alone — so an implausibly large
    /// result is discarded rather than reported as a burst of traffic that
    /// never happened.
    private static func delta(_ previous: UInt32, _ current: UInt32, budget: Double) -> Int64 {
        let stepped = Int64(current &- previous)
        if current >= previous { return stepped }
        return Double(stepped) <= budget ? stepped : 0
    }

    private static func rawCounters() -> [String: Counters] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [:] }
        defer { freeifaddrs(addresses) }

        var result: [String: Counters] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let addr = current.pointee.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_LINK)
            else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let dataPointer = current.pointee.ifa_data else { continue }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Counters(received: data.ifi_ibytes, sent: data.ifi_obytes)
        }
        return result
    }

    /// Reads the true cumulative totals once, from the only source on macOS
    /// that reports them at full width.
    ///
    /// If this fails the sampler simply starts counting from zero, which makes
    /// the totals a session figure instead of a since-boot one. That is a
    /// smaller lie than a number short by an unknown multiple of 4 GiB.
    private static func seedTotals() -> (received: Int64, sent: Int64) {
        guard let output = Shell.run("/usr/sbin/netstat", ["-ibdn"], timeout: 4) else {
            return (0, 0)
        }

        var received: Int64 = 0
        var sent: Int64 = 0
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // Only the link-layer row carries the byte counters; the per-address
            // rows repeat them and would multiply every interface's traffic.
            guard fields.count > 9, fields[2].hasPrefix("<Link") else { continue }

            let name = String(fields[0])
            guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            received += Int64(fields[6]) ?? 0
            sent += Int64(fields[9]) ?? 0
        }
        return (received, sent)
    }
}
