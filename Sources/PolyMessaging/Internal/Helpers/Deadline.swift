// Copyright PolyAI Limited

import Foundation

/// Returns `operation`'s result, or `nil` after `seconds`. Unstructured tasks,
/// not a task group: a group would wait for a handler that ignores cancellation.
func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let race = DeadlineRace<T>()
    return await withCheckedContinuation { continuation in
        race.start(continuation, seconds: seconds, operation)
    }
}

/// First of work / timer to finish resumes the continuation and cancels the other.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?

    func start(
        _ continuation: CheckedContinuation<T?, Never>,
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
        timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.finish(nil, timedOut: true)
        }
        work = Task {
            let value = await operation()
            self.finish(value, timedOut: false)
        }
    }

    private func finish(_ value: T?, timedOut: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let loser = timedOut ? work : timer
        timer = nil
        work = nil
        lock.unlock()

        loser?.cancel()
        continuation.resume(returning: value)
    }
}
