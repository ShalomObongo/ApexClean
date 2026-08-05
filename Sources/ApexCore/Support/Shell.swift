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
        let data = LockedValue(Data())
        let reader = DispatchQueue(label: "fit.apexclean.shell.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            let chunk = pipe.fileHandleForReading.readDataToEndOfFile()
            data.set(chunk)
            done.signal()
        }

        let deadline = DispatchTime.now() + timeout
        if done.wait(timeout: deadline) == .timedOut {
            terminate(process, pipe: pipe)
            _ = done.wait(timeout: .now() + 1)
        }
        _ = exited.wait(timeout: .now() + 1)

        return String(data: data.get(), encoding: .utf8)
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// The outcome of a command whose success actually matters.
    public struct Result {
        public let status: Int32
        /// stdout and stderr combined, in the order the child wrote them.
        public let output: String
        public let timedOut: Bool

        public var succeeded: Bool { !timedOut && status == 0 }

        /// The most useful line to show a person: tools put the real complaint
        /// last, after any progress chatter.
        public var lastMeaningfulLine: String? {
            output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("==>") }
        }
    }

    /// Like `run`, but reports exit status and merges stderr.
    ///
    /// `run` deliberately treats every failure as "no data", which is right for
    /// sampling but wrong for anything the user asked for and is waiting on —
    /// an upgrade that failed must not be reported as an upgrade that worked.
    public static func runDetailed(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 10,
        environment: [String: String]? = nil
    ) -> Result {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Result(status: -1, output: "\(launchPath) is not available", timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Nothing interactive can be answered from here, so close stdin rather
        // than let a tool block forever waiting on a prompt nobody will see.
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }

        let data = LockedValue(Data())
        let reader = DispatchQueue(label: "fit.apexclean.shell.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            let chunk = pipe.fileHandleForReading.readDataToEndOfFile()
            data.set(chunk)
            done.signal()
        }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            terminate(process, pipe: pipe)
            _ = done.wait(timeout: .now() + 2)
        }
        _ = exited.wait(timeout: .now() + 2)

        let output = String(data: data.get(), encoding: .utf8) ?? ""

        let status = process.isRunning ? -1 : process.terminationStatus
        return Result(status: status, output: output, timedOut: timedOut)
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

    private static func terminate(_ process: Process, pipe: Pipe) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // A descendant can inherit the write end and keep the reader blocked
        // after its parent dies. Closing our read end makes timeout bounded.
        try? pipe.fileHandleForReading.close()
    }

    /// A small lock-backed transfer box for values written by a pipe reader and
    /// consumed by the waiting caller.
    private final class LockedValue<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
