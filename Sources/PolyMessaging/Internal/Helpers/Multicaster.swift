// Copyright PolyAI Limited

import Foundation

final class Multicaster<T: Sendable>: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]
    private var lastValue: T?
    private let replayLastValue: Bool
    private let lock = NSLock()

    /// - Parameter replayLastValue: when true, new subscribers immediately
    ///   receive the most-recent emitted value (if any). Use for **state**
    ///   streams (ConnectionStatus, SessionState) where the current value
    ///   matters more than the historical sequence. Leave false for **event**
    ///   streams (MessagingEvent, tick) where replay would re-deliver old
    ///   one-shots.
    init(replayLastValue: Bool = false) {
        self.replayLastValue = replayLastValue
    }

    func subscribe() -> AsyncStream<T> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            let replay = replayLastValue ? lastValue : nil
            lock.unlock()

            // Bring the new subscriber up-to-date with the current state.
            // For state-like streams this closes the cold-subscribe race
            // where the caller subscribes after the producer has already
            // emitted (e.g. eager-start fires before ChatSession subscribes).
            if let replay {
                continuation.yield(replay)
            }

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    func emit(_ value: T) {
        lock.lock()
        if replayLastValue {
            lastValue = value
        }
        let snapshot = continuations.values
        lock.unlock()
        for continuation in snapshot {
            continuation.yield(value)
        }
    }

    func finish() {
        lock.lock()
        let snapshot = continuations.values
        continuations.removeAll()
        lock.unlock()
        for continuation in snapshot {
            continuation.finish()
        }
    }
}
