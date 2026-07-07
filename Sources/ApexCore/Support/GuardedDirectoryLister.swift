import Foundation

/// Lists directory contents with a deadline, on a worker that can be thrown
/// away.
///
/// `contentsOfDirectory` is not interruptible. If the directory sits behind a
/// consent prompt, a stalled file provider, or an offline mount, the call
/// blocks inside `open()` and the calling thread is gone for good — no
/// cancellation flag will ever be read again. A recursive walk that makes that
/// call directly therefore has exactly one unresponsive folder between it and a
/// permanent hang.
///
/// So the call is made on a serial worker instead. The walk waits on a
/// semaphore with a budget; if the budget expires the *worker* is abandoned
/// (it stays parked in the kernel, and unwinds on its own if the syscall ever
/// returns), a replacement is spun up, and the walk carries on having lost one
/// folder rather than everything.
///
/// Abandoning the worker is what makes this correct: a wedged job left at the
/// head of a serial queue would silently swallow every listing after it.
public final class GuardedDirectoryLister {
    private let lock = NSLock()
    private var queue: DispatchQueue
    private var workerIndex = 0
    private var abandoned: [String] = []

    /// Long enough for a cold directory with many thousands of entries on a
    /// slow disk, short enough that a wedge costs a visible pause rather than
    /// the user's patience.
    public static let defaultBudget: TimeInterval = 4

    public init() {
        queue = DispatchQueue(label: "fit.apexclean.lister.0", qos: .userInitiated)
    }

    /// Paths that never answered. Worth showing the user: a map that quietly
    /// omits a folder is a map that lies.
    public var abandonedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return abandoned
    }

    /// Returns the directory's contents, or `nil` if it did not answer in time.
    public func contents(
        of url: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        budget: TimeInterval = GuardedDirectoryLister.defaultBudget
    ) -> [URL]? {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        lock.lock()
        let worker = queue
        lock.unlock()

        worker.async {
            box.set(
                try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: []
                )
            )
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + budget) == .success else {
            replaceWorker(after: url.path)
            return nil
        }
        return box.get() ?? []
    }

    private func replaceWorker(after path: String) {
        lock.lock()
        workerIndex += 1
        queue = DispatchQueue(label: "fit.apexclean.lister.\(workerIndex)", qos: .userInitiated)
        // Only the first few are worth reporting; a hundred names is not a
        // message, it is a wall.
        if abandoned.count < 24 { abandoned.append(path) }
        lock.unlock()
    }

    private final class ResultBox {
        private let lock = NSLock()
        private var value: [URL]?

        func set(_ newValue: [URL]?) {
            lock.lock(); value = newValue; lock.unlock()
        }

        func get() -> [URL]? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
