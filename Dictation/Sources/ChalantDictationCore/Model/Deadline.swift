import Foundation

/// A wait with a budget that is real.
///
/// `withTaskGroup` does not return until every child has finished, and a
/// child that awaits another task's `value` cannot be cancelled. So a
/// "timeout" built as a group of {await task.value, sleep} honours its
/// budget only on paper: the sleep fires, `next()` answers, and the group
/// then sits on the value child until the task is done anyway. The
/// dictation pipeline did exactly this twice over (the polisher's inner
/// budget and the controller's hard deadline on two executors), and from
/// 2026-08-18 to 08-21 every wait ended within microseconds of the model's
/// reply, whatever the budget said. Three days of "something starves the
/// wake" (cooperative-pool sleep, main-actor sleep, zero tolerance, utility
/// hearing, latency-critical activity, raw dispatch timers on two
/// executors) were all aimed at timers that had fired on time. Reproduced
/// in isolation on 2026-08-21: a 200 ms bounded wait on a 3 s task returned
/// nil after 3.04 s. `DeadlineTests` pins it.
///
/// This one races a single continuation between a dispatch timer and an
/// observer of the task; whichever arrives first resumes it, once. The
/// observer is a task nobody waits for, and the watched task is never
/// cancelled: a late reply still lands wherever it was going (the
/// polisher's cache, for the hearing pass).
public enum Deadline {
    /// The task's value if it arrives within `limit`, else nil. The task
    /// keeps running either way.
    public static func value<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T? {
        let once = ResumeOnce<T?>()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds(in: limit)), leeway: .nanoseconds(1))
        timer.setEventHandler { once.resume(nil) }
        timer.resume()
        Task { once.resume(await task.value) }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            once.register(continuation)
        }
        timer.cancel()
        return result
    }

    static func nanoseconds(in duration: Duration) -> Int {
        let whole = duration.components.seconds * 1_000_000_000
        let fraction = duration.components.attoseconds / 1_000_000_000
        return Int(clamping: whole + fraction)
    }
}

/// A continuation resumed exactly once, by whichever side arrives first,
/// in either order: a value that lands before anyone is waiting is held
/// until they are.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, Never>)
        case valued(T)
        case resumed
    }

    private let lock = NSLock()
    private var state: State = .idle

    func register(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        switch state {
        case .idle:
            state = .waiting(continuation)
            lock.unlock()
        case .valued(let value):
            state = .resumed
            lock.unlock()
            continuation.resume(returning: value)
        case .waiting, .resumed:
            // A second waiter cannot happen: one `value(of:within:)` call,
            // one registration. Resuming nothing is the safe answer.
            lock.unlock()
        }
    }

    func resume(_ value: T) {
        lock.lock()
        switch state {
        case .idle:
            state = .valued(value)
            lock.unlock()
        case .waiting(let continuation):
            state = .resumed
            lock.unlock()
            continuation.resume(returning: value)
        case .valued, .resumed:
            // The other side got here first. Ignored, by design.
            lock.unlock()
        }
    }
}
