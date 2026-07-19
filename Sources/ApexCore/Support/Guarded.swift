import Foundation

/// Runs filesystem work with a deadline, on a worker that can be thrown away.
///
/// The problem this exists to solve: a consent-gated path does not make
/// `open()` *fail*, it makes it *block*, inside the kernel, with no deadline
/// and no way to cancel. `Task.cancel()` cannot reach it, a cancellation flag
/// is never read again, and the thread is simply gone. One such path is enough
/// to hang a feature permanently.
///
/// So the work runs on a detached thread and the caller waits on a semaphore.
/// If the budget expires the thread is *abandoned* — it stays parked in the
/// kernel and unwinds on its own if the syscall ever returns — and the caller
/// carries on having lost one path rather than everything.
///
/// A fresh thread per call, rather than a shared queue, is deliberate: a wedged
/// job at the head of a serial queue would silently swallow every job behind it.
public enum Guarded {
    /// Long enough for a cold directory with many thousands of entries on a
    /// slow disk, short enough that a wedge costs a visible pause rather than
    /// the user's patience.
    public static let defaultBudget: TimeInterval = 4

    /// Returns the closure's value, or `nil` if it did not finish in time.
    ///
    /// `work` must be self-contained: once the budget expires nothing it does
    /// will be observed, so it must not mutate state the caller relies on.
    public static func run<T>(
        budget: TimeInterval = Guarded.defaultBudget,
        _ work: @escaping @Sendable () -> T
    ) -> T? {
        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)

        let thread = Thread {
            box.set(work())
            semaphore.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        thread.start()

        guard semaphore.wait(timeout: .now() + budget) == .success else { return nil }
        return box.get()
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?

        func set(_ newValue: T) {
            lock.lock(); value = newValue; lock.unlock()
        }

        func get() -> T? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
}
