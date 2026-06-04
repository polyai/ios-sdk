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
///   * the attempt counter walks 1, 2, 3, ... with NO skipped step,
///   * it never exceeds `maxReconnectAttempts`,
///   * a sub-budget storm does NOT trip the terminal `.failed` breaker.
final class StressReconnectStormTests: XCTestCase {

    private func makeService() -> (ConnectionService, MockConnection) {
        let mock = MockConnection()
        let url = URL(string: "wss://messaging.poly.ai/ws")!
        let service = ConnectionService(transport: mock, wsBaseURL: url, logger: NoopLogger())
        return (service, mock)
    }

    /// 5x code-1006 closes in rapid succession (~120ms apart). The first
    /// reconnect's backoff for attempt 0 is `pow(2,0) * jitter` ≈ 0.8–1.2s, so
    /// the whole ~700ms storm lands inside that first sleep window — no
    /// reconnect actually fires mid-storm. Every close therefore just
    /// reschedules, bumping the attempt counter one step at a time.
    func testRapidReconnectStorm_exhaustsBackoffNotRetrySanely() async {
        let (service, mock) = makeService()

        // Generous budget (default is 10) so a 5-close storm stays sub-budget
        // and we can prove the counter is bounded WITHOUT tripping the breaker.
        await service.setMaxReconnectAttempts(10)

        // Collect every status emission so we can inspect the attempt ladder.
        actor StatusLog {
            private(set) var statuses: [ConnectionStatus] = []
            func append(_ s: ConnectionStatus) { statuses.append(s) }
            func snapshot() -> [ConnectionStatus] { statuses }
        }
        let log = StatusLog()
        let collector = Task {
            for await status in service.statusChanges.subscribe() {
                await log.append(status)
            }
        }

        await service.connectToSession(sessionId: "storm_sess", accessToken: "storm_tok")
        try? await Task.sleep(nanoseconds: 120_000_000) // let open subscriber attach
        mock.simulateOpen()
        try? await Task.sleep(nanoseconds: 120_000_000) // handleOpen -> currentAttemptOpened=true

        // The storm: 5 abnormal closes in rapid succession. We keep the cadence
        // (~120ms) tight enough that all 5 closes complete (~600ms) before even
        // the jitter-minimum of attempt 0's backoff (0.8 * 1s = 0.8s) can fire,
        // so the ladder stays deterministic: no reconnect resets currentAttempt-
        // Opened mid-storm and re-routes a later close to invalid-session.
        for _ in 0..<5 {
            mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        // Settle a moment past the last close (still under the 0.8s floor).
        try? await Task.sleep(nanoseconds: 100_000_000)
        collector.cancel()

        let statuses = await log.snapshot()
        let attempts = statuses.compactMap { status -> Int? in
            if case .reconnecting(let n) = status { return n }
            return nil
        }

        // Each close that re-enters scheduleReconnect bumps the counter, so the
        // 5-close storm yields 5 reconnecting emissions.
        XCTAssertEqual(attempts.count, 5,
                       "each 1006 close should schedule exactly one reconnect; got \(statuses)")

        // INVARIANT: the attempt counter is a contiguous, strictly-increasing
        // 1-based ladder — no step is skipped and none is repeated. With the
        // backoff timer asleep for the whole storm, no reconnect fires to reset
        // the counter, so we expect exactly [1, 2, 3, 4, 5].
        XCTAssertEqual(attempts, [1, 2, 3, 4, 5],
                       "reconnect attempts must walk every step without skipping; got \(attempts)")

        // INVARIANT: never exceed the configured ceiling.
        XCTAssertLessThanOrEqual(attempts.max() ?? 0, 10,
                                 "attempt counter must stay within maxReconnectAttempts")

        // INVARIANT: a sub-budget storm must NOT trip the terminal breaker.
        let failed = statuses.contains { if case .failed = $0 { return true }; return false }
        XCTAssertFalse(failed, "5 closes under a budget of 10 must not emit terminal .failed")

        // The ±20% jitter on attempt 0's ~1s backoff can land as low as 0.8s,
        // so the original reconnect timer MAY fire once inside the ~950ms storm
        // window. What must hold is that the storm never fans out into a flood
        // of overlapping connects: each reschedule cancels the prior timer
        // (`reconnectTask` is reassigned), so at most one extra connect can
        // escape. Bound it: the initial connect plus at most one fired retry.
        XCTAssertLessThanOrEqual(mock.connectCalls.count, 2,
                                 "storm must coalesce into a single live reconnect timer, not a connect flood; got \(mock.connectCalls.count)")
        XCTAssertGreaterThanOrEqual(mock.connectCalls.count, 1,
                                    "the original connect must still be recorded")

        await service.destroy()
    }
}