import Foundation
import AppKit

public struct ProcessVitals: Identifiable, Equatable {
    public var id: Int32
    public var name: String
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var bundleIdentifier: String?
}

public enum ProcessSampler {
    /// Reads the process table via `ps`. The kernel APIs would avoid a fork, but
    /// they need per-process task ports that a non-root, unsandboxed app cannot
    /// reliably obtain — `ps` gives the same numbers Activity Monitor shows.
    public static func topByCPU(limit: Int = 8) -> [ProcessVitals] {
        guard let output = Shell.run("/bin/ps", ["-Aceo", "pid,pcpu,rss,comm", "-r"], timeout: 4) else {
            return []
        }

        var results: [ProcessVitals] = []
        results.reserveCapacity(limit)

        for line in output.split(separator: "\n").dropFirst() {
            if results.count >= limit { break }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Int64(fields[2])
            else { continue }

            let name = fields[3...].joined(separator: " ")
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            results.append(
                ProcessVitals(
                    id: pid,
                    name: name,
                    cpuPercent: cpu,
                    memoryBytes: rssKB * 1024,
                    bundleIdentifier: nil
                )
            )
        }
        return results
    }

    public static func topByMemory(limit: Int = 8) -> [ProcessVitals] {
        guard let output = Shell.run("/bin/ps", ["-Aceo", "pid,pcpu,rss,comm", "-m"], timeout: 4) else {
            return []
        }

        var results: [ProcessVitals] = []
        for line in output.split(separator: "\n").dropFirst() {
            if results.count >= limit { break }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Int64(fields[2])
            else { continue }
            let name = fields[3...].joined(separator: " ")
            results.append(
                ProcessVitals(
                    id: pid,
                    name: name,
                    cpuPercent: cpu,
                    memoryBytes: rssKB * 1024,
                    bundleIdentifier: nil
                )
            )
        }
        return results
    }
}
