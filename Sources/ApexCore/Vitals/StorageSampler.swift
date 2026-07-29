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
        var sawCounterReset = false
        // 64-bit: a busy interface's two 32-bit counters routinely sum past
        // UInt32.max — en0 on this machine is at 3.2 GB in and 2.1 GB out — and
        // a wrapped total would rank it below an idle interface.
        var busiest: UInt64 = 0

        for (name, counters) in raw {
            if let previous = lastRaw[name] {
                if let step = Self.delta(previous.received, counters.received) {
                    receivedDelta += step
                } else {
                    sawCounterReset = true
                }
                if let step = Self.delta(previous.sent, counters.sent) {
                    sentDelta += step
                } else {
                    sawCounterReset = true
                }
            }
            // An interface seen for the first time contributes no delta: its
            // counter already holds history this process never observed.
            let busyness = UInt64(counters.received) + UInt64(counters.sent)
            if busyness > busiest {
                busiest = busyness
                vitals.interface = name
            }
        }

        lastRaw = raw
        lastSampleTime = now
        totalReceived += receivedDelta
        totalSent += sentDelta

        // A counter went backwards, so this sample's arithmetic is unreliable.
        // Rather than guess, ask the one source that knows.
        if sawCounterReset, let truth = Self.seedTotalsIfPossible() {
            totalReceived = truth.received
            totalSent = truth.sent
        }

        vitals.totalReceived = totalReceived
        vitals.totalSent = totalSent

        guard elapsed > 0.05 else { return vitals }
        vitals.downloadBytesPerSecond = Double(receivedDelta) / elapsed
        vitals.uploadBytesPerSecond = Double(sentDelta) / elapsed
        return vitals
    }

    /// Advances a 32-bit odometer, or reports that it cannot be advanced.
    ///
    /// An increase is unambiguous. A decrease is not: the counter either rolled
    /// past `UInt32.max` or the interface restarted, and nothing in the value
    /// tells the two apart. Assuming a rollover invents traffic — from a
    /// counter sitting at 3.0e9, a reset to zero presents as 1.29 GB of
    /// perfectly plausible transfer, which lands in the totals and spikes the
    /// graph. So a decrease returns `nil`, contributes nothing, and the caller
    /// re-reads the true totals instead of guessing at them.
    private static func delta(_ previous: UInt32, _ current: UInt32) -> Int64? {
        current >= previous ? Int64(current - previous) : nil
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
        seedTotalsIfPossible() ?? (0, 0)
    }

    private static func seedTotalsIfPossible() -> (received: Int64, sent: Int64)? {
        guard let output = Shell.run("/usr/sbin/netstat", ["-ibdn"], timeout: 4) else { return nil }
        return parseNetstatTotals(output)
    }

    /// Sums the link-layer rows of `netstat -ibdn`.
    ///
    /// Returns `nil` when a row does not have the expected shape, so the caller
    /// can decline to seed rather than start from a misread number.
    static func parseNetstatTotals(_ output: String) -> (received: Int64, sent: Int64)? {
        var received: Int64 = 0
        var sent: Int64 = 0
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // Only the link-layer row carries the byte counters; the per-address
            // rows repeat them and would multiply every interface's traffic.
            guard fields.count >= 11, fields[2].hasPrefix("<Link") else { continue }

            let name = String(fields[0])
            guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }

            // Counted from the right, because the Address column is *empty* for
            // interfaces without a hardware address. Those rows have eleven
            // fields where the rest have twelve, so fixed indices read Opkts as
            // Ibytes and Coll as Obytes. `pktap0` on this machine is exactly
            // that shape and is not filtered out, and a VPN interface would be
            // too. The trailing columns of `netstat -ibdn` are fixed:
            // Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll Drop.
            let end = fields.count
            guard let inBytes = Int64(fields[end - 6]), let outBytes = Int64(fields[end - 3])
            else {
                // The layout is not what this parser was written for. Seeding
                // from a misread column would put the totals permanently wrong
                // by an arbitrary amount, so decline the seed instead and let
                // the totals count from zero for this session.
                return nil
            }
            received += inBytes
            sent += outBytes
        }
        return (received, sent)
    }
}
