// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress probes for the reconnect state machine in
/// `Sources/PolyMessaging/Internal/Services/ConnectionService.swift`.
///
/// A "reconnect storm" is a burst of abnormal (1006) closes arriving faster
/// than the exponential-backoff timer can actually fire a reconnect. Each
/// close re-enters `handleClose` -> `scheduleReconnect`, which increments
/// `reconnectAttempt` and emits `.reconnecting(attempt:)`. The invariants we
/// pin here:
///   * the attempt counter walks 1, 2, 3, ... with NO skipped step and no
///     repeat,
///   * it never exceeds `maxReconnectAttempts`,
///   * a sub-budget storm does NOT trip the terminal `.failed` breaker, while
///     an over-budget storm DOES (and emits both a terminal closeEvent and
///     `.failed`).
///
/// Timing note: the backoff for attempt 0 is `pow(2,0) * jitter` ≈ 0.8–1.2s.
/// Rather than *hope* the storm out-races that floor with fixed sleeps (flaky
/// on a slow box, where a reconnect can fire mid-storm, reset
/// `currentAttemptOpened`, and re-route a later close to invalid-session), we
/// drive every close with a poll-until-condition wait and then explicitly
/// `cancelReconnect()` the just-scheduled timer. That guarantees no reconnect
/// fires mid-storm regardless of host speed, so the ladder is deterministic
/// and the assertions below are pure invariants, not jitter-dependent races.
final class StressReconnectStormTests: XCTestCase {

    /// Thread-safe sink for status emissions consumed on a background Task.
    private actor StatusLog {
        private(set) var statuses: [ConnectionStatus] = []
        func append(_ s: ConnectionStatus) { statuses.append(s) }
        func snapshot() -> [ConnectionStatus] { statuses }

        var reconnectAttempts: [Int] {
            statuses.compactMap { if case .reconnecting(let n) = $0 { return n }; return nil }
        }
        var sawFailed: Bool {
            statuses.contains { if case .failed = $0 { return true }; return false }
        }
        func sawStatus(_ predicate: (ConnectionStatus) -> Bool) -> Bool {
            statuses.contains(where: predicate)
        }
    }

    /// Thread-safe sink for close-event reasons consumed on a background Task.
    private actor CloseLog {
        private(set) var reasons: [String] = []
        func append(_ r: String) { reasons.append(r) }
        func snapshot() -> [String] { reasons }
    }

    private func makeService() -> (ConnectionService, MockConnection) {
        let mock = MockConnection()
        let url = URL(string: "wss://messaging.poly.ai/ws")!
        let service = ConnectionService(transport: mock, wsBaseURL: url, logger: NoopLogger())
        return (service, mock)
    }

    /// Polls `condition` until true or `timeout` elapses (default 5s, ~20ms
    /// cadence). Returns the final value of the condition.
    @discardableResult
    private func poll(timeout: TimeInterval = 5.0, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// Subscribes a background collector to `statusChanges`. `statusChanges` is
    /// a replay-last Multicaster, so once the collector's loop is running it
    /// reliably observes the current status; callers confirm attachment by
    /// polling for the first emission rather than sleeping a fixed interval.
    private func startCollector(
        on service: ConnectionService,
        into log: StatusLog
    ) -> Task<Void, Never> {
        Task {
            for await status in service.statusChanges.subscribe() {
                await log.append(status)
            }
        }
    }

    /// Re-emits `simulateOpen()` until the service observes `.open` (or the
    /// timeout elapses). The transport's `openEvents`/`closeEvents` casters are
    /// non-replay and the service subscribes only after `connect()` returns, so
    /// a single emit can race the subscriber attach. `simulateOpen` is
    /// idempotent (sets status + emits), so re-emitting is safe and, once the
    /// open subscriber loop has run, also proves the sibling close subscriber
    /// (created in the same `startObserving()` pass) is attached before the
    /// storm's first — non-idempotent — close is driven.
    @discardableResult
    private func driveOpen(_ mock: MockConnection, observedBy log: StatusLog) async -> Bool {
        await poll {
            if await log.sawStatus({ if case .open = $0 { return true }; return false }) {
                return true
            }
            mock.simulateOpen()
            // Give the observation task a beat to deliver before re-checking.
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await log.sawStatus { if case .open = $0 { return true }; return false }
        }
    }

    // MARK: - Sub-budget storm: contiguous ladder, no breaker trip

    /// 5x code-1006 closes under a budget of 10. Each close re-enters
    /// `scheduleReconnect`, bumping the attempt counter exactly once. We cancel
    /// the scheduled timer after each step so no reconnect fires mid-storm,
    /// making the ladder deterministic without depending on the jitter floor.
    func testRapidReconnectStorm_walksContiguousLadderUnderBudget() async {
        let (service, mock) = makeService()

        // Generous budget (default is 10) so a 5-close storm stays sub-budget
        // and we can prove the counter is bounded WITHOUT tripping the breaker.
        await service.setMaxReconnectAttempts(10)

        let log = StatusLog()
        let collector = startCollector(on: service, into: log)

        await service.connectToSession(sessionId: "storm_sess", accessToken: "storm_tok")
        // Confirm the collector attached and saw the initial .connecting before
        // we drive any closes (replaces a fixed "let subscriber attach" sleep).
        let attached = await poll {
            await log.sawStatus { if case .connecting = $0 { return true }; return false }
        }
        XCTAssertTrue(attached, "status collector must observe the initial .connecting")

        // Open the socket so subsequent 1006 closes are treated as abnormal
        // drops (not handshake failures) and route through scheduleReconnect.
        // The transport's openEvents Multicaster is non-replay and the service
        // subscribes to it only after connect() returns, so a single emit can
        // race the subscriber attach. Re-emit open until the service observes
        // it (idempotent: simulateOpen just sets status + emits).
        let opened = await driveOpen(mock, observedBy: log)
        XCTAssertTrue(opened, "handleOpen must run so currentAttemptOpened=true")

        // The storm: 5 abnormal closes. After each close we wait for the
        // matching .reconnecting emission, then cancel the freshly-scheduled
        // reconnect timer so it can NEVER fire mid-storm — this is what keeps
        // the ladder deterministic on a slow box (no jitter-floor assumption).
        for expected in 1...5 {
            mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
            let bumped = await poll { await log.reconnectAttempts.count >= expected }
            let ladder = await log.reconnectAttempts
            XCTAssertTrue(bumped, "close #\(expected) must schedule a reconnect; got \(ladder)")
            // Kill the pending timer so no reconnect fires and resets state.
            await service.cancelReconnect()
        }

        collector.cancel()
        let statuses = await log.snapshot()
        let attempts = await log.reconnectAttempts

        // Each close that re-enters scheduleReconnect bumps the counter, so the
        // 5-close storm yields exactly 5 reconnecting emissions.
        XCTAssertEqual(attempts.count, 5,
                       "each 1006 close should schedule exactly one reconnect; got \(statuses)")

        // INVARIANT: the emitted attempt counter is a contiguous, strictly-
        // increasing, 1-based ladder — no step skipped, none repeated. Asserted
        // as an invariant rather than literal [1,2,3,4,5] so the probe holds
        // regardless of jitter (here, with timers cancelled, it equals that).
        assertContiguousAscendingLadder(attempts)

        // INVARIANT: never exceed the configured ceiling (budget == 10).
        XCTAssertLessThanOrEqual(attempts.max() ?? 0, 10,
                                 "attempt counter must stay within maxReconnectAttempts (10)")

        // INVARIANT: a sub-budget storm must NOT trip the terminal breaker.
        let failed = await log.sawFailed
        XCTAssertFalse(failed, "5 closes under a budget of 10 must not emit terminal .failed")

        // INVARIANT: no connect flood. With every scheduled timer cancelled,
        // only the initial connect was ever issued.
        XCTAssertEqual(mock.connectCalls.count, 1,
                       "storm must not fan out into a connect flood; got \(mock.connectCalls.count)")

        await service.destroy()
    }

    // MARK: - Over-budget storm: breaker boundary

    /// Drives the breaker to its boundary with a small, explicit budget. With
    /// `maxReconnectAttempts == 3`, closes 1..3 walk the ladder to attempt 3
    /// (== budget) and the 4th close trips the guard: `scheduleReconnect` emits
    /// the terminal `.failed` status AND a "Max reconnect attempts exceeded"
    /// closeEvent (invariant I15 — Coordinator needs both). This exercises the
    /// boundary the old `XCTAssertLessThanOrEqual(max, 10)` non-assertion never
    /// touched.
    func testReconnectStorm_overBudget_tripsBreakerAtCeiling() async {
        let (service, mock) = makeService()

        let budget = 3
        await service.setMaxReconnectAttempts(budget)

        let log = StatusLog()
        let collector = startCollector(on: service, into: log)

        // Capture the terminal closeEvent separately. closeEvents is event-like
        // (non-replay), so subscribe BEFORE any close is driven, and confirm the
        // ladder is observable before relying on it.
        let closeLog = CloseLog()
        let closeCollector = Task {
            for await ev in service.closeEvents.subscribe() {
                await closeLog.append(ev.reason)
            }
        }

        await service.connectToSession(sessionId: "over_sess", accessToken: "over_tok")
        let attached = await poll {
            await log.sawStatus { if case .connecting = $0 { return true }; return false }
        }
        XCTAssertTrue(attached, "status collector must observe the initial .connecting")

        let opened = await driveOpen(mock, observedBy: log)
        XCTAssertTrue(opened, "handleOpen must run so currentAttemptOpened=true")

        // Walk the ladder to the ceiling: closes 1..budget each bump the
        // counter. Cancel the scheduled timer after each so no reconnect fires
        // mid-storm (timing-independent).
        for expected in 1...budget {
            mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
            let bumped = await poll { await log.reconnectAttempts.count >= expected }
            let ladder = await log.reconnectAttempts
            XCTAssertTrue(bumped, "close #\(expected) must bump the ladder; got \(ladder)")
            await service.cancelReconnect()
        }

        // One more close: reconnectAttempt now == budget, so the guard trips
        // and the breaker fires the terminal close + .failed.
        mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
        let tripped = await poll { await log.sawFailed }
        let finalStatuses = await log.snapshot()
        XCTAssertTrue(tripped, "over-budget close must emit terminal .failed; got \(finalStatuses)")

        collector.cancel()
        closeCollector.cancel()

        let attempts = await log.reconnectAttempts

        // INVARIANT: the ladder is still contiguous & strictly increasing up to
        // the breaker.
        assertContiguousAscendingLadder(attempts)

        // INVARIANT: the emitted ladder reaches exactly the budget and never
        // exceeds it. The breaker trips on the close AFTER attempt == budget,
        // so no `.reconnecting(budget+1)` is ever emitted.
        XCTAssertEqual(attempts.max() ?? 0, budget,
                       "ladder must reach exactly the budget (\(budget)) before the breaker; got \(attempts)")
        XCTAssertEqual(attempts.count, budget,
                       "exactly \(budget) reconnect attempts must be emitted before the breaker; got \(attempts)")

        // INVARIANT (I15): the breaker emits a terminal closeEvent so Coordinator
        // can surface the failure — not just the status change.
        let closeReasons = await closeLog.snapshot()
        XCTAssertTrue(closeReasons.contains { $0.contains("Max reconnect") },
                      "breaker must emit a 'Max reconnect attempts exceeded' closeEvent (I15); got \(closeReasons)")

        await service.destroy()
    }

    // MARK: - Invariant helper

    /// Asserts `attempts` is a contiguous, strictly-increasing, 1-based ladder
    /// (1, 2, 3, ... with no skipped step and no repeat).
    private func assertContiguousAscendingLadder(
        _ attempts: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let first = attempts.first else {
            XCTFail("expected a non-empty reconnect ladder", file: file, line: line)
            return
        }
        XCTAssertEqual(first, 1, "ladder must start at attempt 1; got \(attempts)", file: file, line: line)
        for (i, value) in attempts.enumerated() {
            XCTAssertEqual(value, i + 1,
                           "reconnect attempts must walk every step without skipping or repeating; got \(attempts)",
                           file: file, line: line)
        }
    }
}