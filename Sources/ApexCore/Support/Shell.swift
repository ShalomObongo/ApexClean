import Darwin
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
        do {
            let execution = try execute(
                launchPath,
                arguments,
                timeout: timeout,
                mergeStandardError: false,
                environment: nil
            )
            guard !execution.timedOut else { return nil }
            return String(data: execution.output, encoding: .utf8)
        } catch {
            return nil
        }
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

        do {
            let execution = try execute(
                launchPath,
                arguments,
                timeout: timeout,
                mergeStandardError: true,
                environment: environment
            )
            return Result(
                status: execution.status,
                output: String(decoding: execution.output, as: UTF8.self),
                timedOut: execution.timedOut
            )
        } catch {
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }
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

    private struct Execution {
        let status: Int32
        let output: Data
        let timedOut: Bool
    }

    private struct LaunchFailure: LocalizedError {
        let code: Int32

        var errorDescription: String? {
            String(cString: strerror(code))
        }
    }

    /// Launches the command in a dedicated process group. The group boundary is
    /// important: polling a parent for children can miss a short-lived shell
    /// that reparents a long-lived child before the first observation.
    private static func execute(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval,
        mergeStandardError: Bool,
        environment: [String: String]?
    ) throws -> Execution {
        let pipe = Pipe()
        let readHandle = try movedAboveStandardDescriptors(pipe.fileHandleForReading)
        let writeHandle = try movedAboveStandardDescriptors(pipe.fileHandleForWriting)
        let readFD = readHandle.fileDescriptor
        let writeFD = writeHandle.fileDescriptor
        let outputPipeHandle = pipeHandle(pid: getpid(), descriptor: writeFD)
        let supervisionPipe = Pipe()
        let supervisionRead = try movedAboveStandardDescriptors(
            supervisionPipe.fileHandleForReading
        )
        let supervisionWrite = try movedAboveStandardDescriptors(
            supervisionPipe.fileHandleForWriting
        )
        let supervisionReadFD = supervisionRead.fileDescriptor
        let supervisionWriteFD = supervisionWrite.fileDescriptor
        let occupied = Set([readFD, writeFD, supervisionReadFD, supervisionWriteFD])
        var supervisionDescriptor: Int32 = 198
        while occupied.contains(supervisionDescriptor)
            || fcntl(supervisionDescriptor, F_GETFD) >= 0
        {
            supervisionDescriptor += 1
        }
        let supervisionPipeHandle = pipeHandle(
            pid: getpid(),
            descriptor: supervisionWriteFD
        )
        let currentFlags = fcntl(supervisionReadFD, F_GETFL)
        guard currentFlags >= 0,
            fcntl(supervisionReadFD, F_SETFL, currentFlags | O_NONBLOCK) == 0
        else { throw LaunchFailure(code: errno) }

        var actions: posix_spawn_file_actions_t?
        try requirePOSIX(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        try requirePOSIX(posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO))
        try requirePOSIX(
            posix_spawn_file_actions_adddup2(
                &actions,
                supervisionWriteFD,
                supervisionDescriptor
            )
        )
        if mergeStandardError {
            try requirePOSIX(posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO))
        } else {
            try requirePOSIX(
                "/dev/null".withCString {
                    posix_spawn_file_actions_addopen(
                        &actions,
                        STDERR_FILENO,
                        $0,
                        O_WRONLY,
                        0
                    )
                }
            )
        }
        try requirePOSIX(
            "/dev/null".withCString {
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0)
            }
        )
        try requirePOSIX(posix_spawn_file_actions_addclose(&actions, readFD))
        try requirePOSIX(posix_spawn_file_actions_addclose(&actions, writeFD))
        try requirePOSIX(posix_spawn_file_actions_addclose(&actions, supervisionReadFD))
        try requirePOSIX(posix_spawn_file_actions_addclose(&actions, supervisionWriteFD))

        var attributes: posix_spawnattr_t?
        try requirePOSIX(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try requirePOSIX(posix_spawnattr_setpgroup(&attributes, 0))
        try requirePOSIX(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            )
        )

        let commandEnvironment = environment ?? ProcessInfo.processInfo.environment
        let environmentStrings =
            commandEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var pid: pid_t = 0
        let spawnStatus = try withCStringArray([launchPath] + arguments) { argv in
            try withCStringArray(environmentStrings) { envp in
                launchPath.withCString { path in
                    posix_spawn(&pid, path, &actions, &attributes, argv, envp)
                }
            }
        }
        try requirePOSIX(spawnStatus)
        let spawnedPID = pid
        let rootIdentity = ProcessIdentity(spawnedPID)

        // Only the child may retain the write side now. This lets EOF prove the
        // whole process group released its inherited output descriptors.
        try? writeHandle.close()
        try? supervisionWrite.close()

        let descendants = DescendantTracker(rootPID: spawnedPID)
        descendants.start()
        defer { descendants.stop() }

        let completion = DispatchGroup()
        let data = LockedValue(Data())
        completion.enter()
        DispatchQueue(label: "fit.apexclean.shell.read").async {
            let chunk = readHandle.readDataToEndOfFile()
            data.set(chunk)
            try? readHandle.close()
            completion.leave()
        }

        // Observe without reaping. Retaining the root as a zombie until timeout
        // cleanup is complete reserves both its PID and process-group ID, so a
        // recycled numeric ID can never make a group signal hit another app.
        completion.enter()
        DispatchQueue(label: "fit.apexclean.shell.wait").async {
            observeExit(of: spawnedPID)
            completion.leave()
        }

        let deadline = DispatchTime.now() + max(0, timeout)
        var timedOut = completion.wait(timeout: deadline) == .timedOut
        if timedOut {
            terminate(
                processGroup: spawnedPID,
                rootIdentity: rootIdentity,
                readHandle: readHandle,
                outputPipeHandle: outputPipeHandle,
                supervisionPipeHandle: supervisionPipeHandle,
                knownDescendants: descendants.snapshot()
            )
            _ = completion.wait(timeout: .now() + 2)
        } else if pipeHasWriter(supervisionRead) {
            timedOut = terminateSupervisionPipeHolders(
                handle: supervisionPipeHandle,
                startedAfter: rootIdentity
            )
        }
        try? supervisionRead.close()
        let waitStatus = reap(spawnedPID)

        return Execution(
            status: decodedExitStatus(waitStatus),
            output: data.get(),
            timedOut: timedOut
        )
    }

    private static func movedAboveStandardDescriptors(_ handle: FileHandle) throws -> FileHandle {
        let descriptor = handle.fileDescriptor
        if descriptor > STDERR_FILENO {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0,
                fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
            else { throw LaunchFailure(code: errno) }
            return handle
        }
        let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard moved >= 0 else { throw LaunchFailure(code: errno) }
        do {
            try handle.close()
        } catch {
            close(moved)
            throw error
        }
        return FileHandle(fileDescriptor: moved, closeOnDealloc: true)
    }

    private static func requirePOSIX(_ code: Int32) throws {
        if code != 0 { throw LaunchFailure(code: code) }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                pointers.forEach { free($0) }
                throw LaunchFailure(code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }

        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func decodedExitStatus(_ waitStatus: Int32?) -> Int32 {
        guard let waitStatus else { return -1 }
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return (waitStatus >> 8) & 0xFF
        }
        return signal == 0x7F ? -1 : signal
    }

    private static func observeExit(of pid: pid_t) {
        while true {
            var information = siginfo_t()
            let result = waitid(
                P_PID,
                id_t(pid),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0, information.si_pid != 0 { return }
            if result != 0, errno != EINTR { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func reap(_ pid: pid_t) -> Int32? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return status }
            if waited == -1 {
                if errno == EINTR { continue }
                return nil
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private static func terminate(
        processGroup: pid_t,
        rootIdentity: ProcessIdentity?,
        readHandle: FileHandle,
        outputPipeHandle: UInt64?,
        supervisionPipeHandle: UInt64?,
        knownDescendants: Set<ProcessIdentity>
    ) {
        let descendants =
            knownDescendants
            .union(descendantPIDs(of: processGroup).compactMap(ProcessIdentity.init))
            .union(pipeHolders(of: outputPipeHandle))
            .union(pipeHolders(of: supervisionPipeHandle))
        _ = kill(-processGroup, SIGTERM)
        for identity in descendants where identity.isCurrent {
            _ = kill(identity.pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(1)
        while (rootIdentity?.isActive == true || descendants.contains(where: \.isActive)),
            Date() < deadline
        {
            Thread.sleep(forTimeInterval: 0.02)
        }

        _ = kill(-processGroup, SIGKILL)
        let survivors =
            descendants
            .union(descendantPIDs(of: processGroup).compactMap(ProcessIdentity.init))
            .union(pipeHolders(of: outputPipeHandle))
            .union(pipeHolders(of: supervisionPipeHandle))
        for identity in survivors where identity.isCurrent {
            _ = kill(identity.pid, SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(1)
        while survivors.contains(where: \.isActive), Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        // A process that deliberately leaves the group can still retain the
        // pipe. Closing our read end keeps the timeout bounded in that case.
        try? readHandle.close()
    }

    private static func terminate(_ identities: Set<ProcessIdentity>) {
        for identity in identities where identity.isCurrent {
            _ = kill(identity.pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(1)
        while identities.contains(where: \.isActive), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        for identity in identities where identity.isCurrent {
            _ = kill(identity.pid, SIGKILL)
        }
    }

    private static func pipeHasWriter(_ readHandle: FileHandle) -> Bool {
        var byte: UInt8 = 0
        let count = Darwin.read(readHandle.fileDescriptor, &byte, 1)
        if count == 0 { return false }
        return count > 0 || errno == EAGAIN || errno == EWOULDBLOCK
    }

    /// A daemonizing child can fork again after the root has exited. The
    /// inherited supervision descriptor survives closed stdio, so observe a
    /// short settling window and terminate every holder of that exact pipe.
    private static func terminateSupervisionPipeHolders(
        handle: UInt64?,
        startedAfter root: ProcessIdentity?
    ) -> Bool {
        guard let handle else { return false }
        let deadline = Date().addingTimeInterval(0.15)
        var found = Set<ProcessIdentity>()
        repeat {
            let holders = pipeHolders(of: handle).filter {
                root == nil || $0.startedAtOrAfter(root!)
            }
            for identity in holders.subtracting(found) where identity.isCurrent {
                _ = kill(identity.pid, SIGTERM)
            }
            found.formUnion(holders)
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        guard !found.isEmpty else { return false }
        terminate(found.union(pipeHolders(of: handle)))
        return true
    }

    private struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        init?(_ pid: pid_t) {
            guard let information = Shell.processInformation(pid) else { return nil }
            self.pid = pid
            startSeconds = information.pbi_start_tvsec
            startMicroseconds = information.pbi_start_tvusec
        }

        var isCurrent: Bool {
            guard let information = Shell.processInformation(pid) else { return false }
            return information.pbi_start_tvsec == startSeconds
                && information.pbi_start_tvusec == startMicroseconds
        }

        var isActive: Bool {
            guard let information = Shell.processInformation(pid),
                information.pbi_start_tvsec == startSeconds,
                information.pbi_start_tvusec == startMicroseconds
            else { return false }
            return information.pbi_status != SZOMB
        }

        func startedAtOrAfter(_ other: ProcessIdentity) -> Bool {
            (startSeconds, startMicroseconds)
                >= (other.startSeconds, other.startMicroseconds)
        }
    }

    private static func processInformation(_ pid: pid_t) -> proc_bsdinfo? {
        var information = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let copied = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &information,
            expected
        )
        return copied == expected ? information : nil
    }

    private static func descendantPIDs(of parent: pid_t) -> [pid_t] {
        let capacity = proc_listchildpids(parent, nil, 0)
        guard capacity > 0 else { return [] }

        var children = [pid_t](
            repeating: 0,
            count: Int(capacity)
        )
        let filled = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }

        let count = Int(filled)
        let direct = Array(children.prefix(count)).filter { $0 > 0 }
        return direct + direct.flatMap(descendantPIDs)
    }

    private static func pipeHandle(pid: pid_t, descriptor: Int32) -> UInt64? {
        var information = pipe_fdinfo()
        let expected = Int32(MemoryLayout<pipe_fdinfo>.stride)
        let copied = proc_pidfdinfo(
            pid,
            descriptor,
            PROC_PIDFDPIPEINFO,
            &information,
            expected
        )
        return copied == expected ? information.pipeinfo.pipe_handle : nil
    }

    /// Finds descendants that escaped the original process group or session but
    /// still retain the output pipe. The scan runs only on timeout and validates
    /// PID start time before any signal, so numeric PID reuse cannot hit an
    /// unrelated process.
    private static func pipeHolders(of handle: UInt64?) -> Set<ProcessIdentity> {
        guard let handle else { return [] }
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }

        var holders = Set<ProcessIdentity>()
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != getpid() {
            guard let identity = ProcessIdentity(pid),
                let process = processInformation(pid),
                process.pbi_uid == getuid()
            else { continue }

            let byteCapacity = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard byteCapacity > 0 else { continue }
            var descriptors = [proc_fdinfo](
                repeating: proc_fdinfo(),
                count: Int(byteCapacity) / MemoryLayout<proc_fdinfo>.stride
            )
            let bytes = descriptors.withUnsafeMutableBytes {
                proc_pidinfo(
                    pid,
                    PROC_PIDLISTFDS,
                    0,
                    $0.baseAddress,
                    Int32($0.count)
                )
            }
            guard bytes > 0 else { continue }
            let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
            let ownsPipe = descriptors.prefix(count).contains { descriptor in
                guard descriptor.proc_fdtype == PROX_FDTYPE_PIPE else { return false }
                return pipeHandle(pid: pid, descriptor: descriptor.proc_fd) == handle
            }
            if ownsPipe, identity.isCurrent { holders.insert(identity) }
        }
        return holders
    }

    private final class DescendantTracker: @unchecked Sendable {
        private let rootPID: pid_t
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "fit.apexclean.shell.descendants")
        private var timer: DispatchSourceTimer?
        private var known: Set<ProcessIdentity> = []

        init(rootPID: pid_t) {
            self.rootPID = rootPID
        }

        func start() {
            capture()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.capture() }
            timer.resume()
            self.timer = timer
        }

        func stop() {
            timer?.cancel()
            timer = nil
        }

        func snapshot() -> Set<ProcessIdentity> {
            lock.lock()
            defer { lock.unlock() }
            return known
        }

        private func capture() {
            let descendants = Set(
                Shell.descendantPIDs(of: rootPID).compactMap(ProcessIdentity.init)
            )
            guard !descendants.isEmpty else { return }
            lock.lock()
            known.formUnion(descendants)
            lock.unlock()
        }
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
