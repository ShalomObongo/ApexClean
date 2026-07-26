import Foundation
import os

public enum Log {
    private static let subsystem = "fit.apexclean.core"

    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let safety = Logger(subsystem: subsystem, category: "safety")
    public static let vitals = Logger(subsystem: subsystem, category: "vitals")
}

/// Minimal, timeout-bounded process runner. Every call site in ApexCore treats a
/// failure as "no data" rather than an error worth surfacing, so this never throws.
public enum Shell {
    @discardableResult
    public static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 10
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Deliberately not `waitUntilExit()`. That method spins the current run
        // loop, so calling it from the main thread re-enters AppKit and SwiftUI
        // mid-update. A termination handler plus a semaphore blocks the calling
        // thread honestly instead, which is the behaviour every call site wants.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read on a background queue so a chatty child cannot deadlock on a full pipe.
        var data = Data()
        let lock = NSLock()
        let reader = DispatchQueue(label: "fit.apexclean.shell.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            let chunk = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            data = chunk
            lock.unlock()
            done.signal()
        }

        let deadline = DispatchTime.now() + timeout
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
        }
        _ = exited.wait(timeout: .now() + 1)

        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// Resolves a tool from the small set of locations ApexClean is willing to trust.
    public static func which(_ tool: String) -> String? {
        let roots = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for root in roots {
            let candidate = "\(root)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
