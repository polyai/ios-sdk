// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress probes for the reconnect state machine in `ConnectionService`. A
/// "reconnect storm" is a burst of 1006 closes arriving faster than backoff can
/// fire a reconnect. Invariants pinned: the attempt counter walks 1,2,3,... with
/// no skipped/repeated step, never exceeds `maxReconnectAttempts`, and a
/// sub-budget storm does NOT trip `.failed` while an over-budget storm does
/// (emitting both a terminal closeEvent and `.failed`).
///
/// We `cancelReconnect()` the just-scheduled timer after each close so no
/// reconnect fires mid-storm (which would reset `currentAttemptOpened` and
/// re-route a later close to invalid-session); this makes the ladder
/// deterministic regardless of host speed rather than depending on the jitter floor.
final class StressReconnectStormTests: XCTestCase {

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

    /// Polls `condition` until true or `timeout` elapses. Returns the final value.
    @discardableResult
    private func poll(timeout: TimeInterval = 5.0, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// Subscribes a background collector to `statusChanges` (a replay-last
    /// Multicaster, so the loop reliably observes the current status).
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

    /// Re-emits `simulateOpen()` until the service observes `.open`. The
    /// transport's open/close casters are non-replay and subscribed only after
    /// `connect()` returns, so a single emit can race the subscriber attach;
    /// `simulateOpen` is idempotent so re-emitting is safe. Once it lands, the
    /// sibling close subscriber (same `startObserving()` pass) is also attached
    /// before the storm's first — non-idempotent — close is driven.
    @discardableResult
    private func driveOpen(_ mock: MockConnection, observedBy log: StatusLog) async -> Bool {
        await poll {
            if await log.sawStatus({ if case .open = $0 { return true }; return false }) {
                return true
            }
            mock.simulateOpen()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await log.sawStatus { if case .open = $0 { return true }; return false }
        }
    }

    // MARK: - Sub-budget storm: contiguous ladder, no breaker trip

    /// 5x 1006 closes under a budget of 10: counter walks a contiguous ladder,
    /// breaker does not trip.
    func testRapidReconnectStorm_walksContiguousLadderUnderBudget() async {
        let (service, mock) = makeService()

        await service.setMaxReconnectAttempts(10)

        let log = StatusLog()
        let collector = startCollector(on: service, into: log)

        await service.connectToSession(sessionId: "storm_sess", accessToken: "storm_tok")
        let attached = await poll {
            await log.sawStatus { if case .connecting = $0 { return true }; return false }
        }
        XCTAssertTrue(attached, "status collector must observe the initial .connecting")

        // Open the socket so subsequent 1006 closes are treated as abnormal
        // drops (not handshake failures) and route through scheduleReconnect.
        let opened = await driveOpen(mock, observedBy: log)
        XCTAssertTrue(opened, "handleOpen must run so currentAttemptOpened=true")

        for expected in 1...5 {
            mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
            let bumped = await poll { await log.reconnectAttempts.count >= expected }
            let ladder = await log.reconnectAttempts
            XCTAssertTrue(bumped, "close #\(expected) must schedule a reconnect; got \(ladder)")
            await service.cancelReconnect()
        }

        collector.cancel()
        let statuses = await log.snapshot()
        let attempts = await log.reconnectAttempts

        XCTAssertEqual(attempts.count, 5,
                       "each 1006 close should schedule exactly one reconnect; got \(statuses)")

        // INVARIANT: contiguous, strictly-increasing, 1-based ladder. Asserted as
        // an invariant rather than literal [1,2,3,4,5] so it holds regardless of jitter.
        assertContiguousAscendingLadder(attempts)

        // INVARIANT: never exceed the configured ceiling (budget == 10).
        XCTAssertLessThanOrEqual(attempts.max() ?? 0, 10,
                                 "attempt counter must stay within maxReconnectAttempts (10)")

        // INVARIANT: a sub-budget storm must NOT trip the terminal breaker.
        let failed = await log.sawFailed
        XCTAssertFalse(failed, "5 closes under a budget of 10 must not emit terminal .failed")

        // INVARIANT: no connect flood — only the initial connect was issued.
        XCTAssertEqual(mock.connectCalls.count, 1,
                       "storm must not fan out into a connect flood; got \(mock.connectCalls.count)")

        await service.destroy()
    }

    // MARK: - Over-budget storm: breaker boundary

    /// With `maxReconnectAttempts == 3`, closes 1..3 walk the ladder to attempt 3
    /// and the 4th close trips the guard: `scheduleReconnect` emits the terminal
    /// `.failed` status AND a "Max reconnect attempts exceeded" closeEvent
    /// (invariant I15 — Coordinator needs both).
    func testReconnectStorm_overBudget_tripsBreakerAtCeiling() async {
        let (service, mock) = makeService()

        let budget = 3
        await service.setMaxReconnectAttempts(budget)

        let log = StatusLog()
        let collector = startCollector(on: service, into: log)

        // closeEvents is non-replay, so subscribe BEFORE any close is driven.
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

        for expected in 1...budget {
            mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
            let bumped = await poll { await log.reconnectAttempts.count >= expected }
            let ladder = await log.reconnectAttempts
            XCTAssertTrue(bumped, "close #\(expected) must bump the ladder; got \(ladder)")
            await service.cancelReconnect()
        }

        // reconnectAttempt now == budget, so this close trips the guard.
        mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
        let tripped = await poll { await log.sawFailed }
        let finalStatuses = await log.snapshot()
        XCTAssertTrue(tripped, "over-budget close must emit terminal .failed; got \(finalStatuses)")

        collector.cancel()
        closeCollector.cancel()

        let attempts = await log.reconnectAttempts

        // INVARIANT: contiguous & strictly increasing up to the breaker.
        assertContiguousAscendingLadder(attempts)

        // INVARIANT: ladder reaches exactly the budget — the breaker trips on the
        // close AFTER attempt == budget, so no `.reconnecting(budget+1)` is emitted.
        XCTAssertEqual(attempts.max() ?? 0, budget,
                       "ladder must reach exactly the budget (\(budget)) before the breaker; got \(attempts)")
        XCTAssertEqual(attempts.count, budget,
                       "exactly \(budget) reconnect attempts must be emitted before the breaker; got \(attempts)")

        // INVARIANT (I15): breaker emits a terminal closeEvent (not just the
        // status change) so Coordinator can surface the failure.
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