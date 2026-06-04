// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress probes for the handshake + invalid-session path. Two invariants:
///  1. Repeated handshake failures must not stack observation tasks — one
///     inbound frame still delivered exactly once after many reconnect cycles.
///  2. The invalid-session refetch chain is bounded by
///     ConnectionService.maxInvalidSessionAttempts (3); the 4th 4001 must
///     terminate in `.failed`, not loop refetching forever.
/// Backoff is jittered exponential, so we never assert *when* a reconnect
/// fires — only count/status invariants, reached via poll-until waits.
final class StressHandshakeTests: XCTestCase {

    // MARK: - Builders (mirror ResilienceMatrixTests)

    private func makeCoordinator(
        sessionTimeoutSeconds: TimeInterval = 3600
    ) async -> (Coordinator, MockRestApi, MockConnection) {
        // Clear stored session so a prior run doesn't short-circuit resume() and skip createSession.
        SessionStore(apiKey: "test_token").clear()
        let api = MockRestApi()
        let connection = MockConnection()
        let config = Configuration(apiKey: "test_token", environment: .us)
        let logger = NoopLogger()
        let session = SessionService(api: api, config: config, logger: logger,
                                     sessionTimeoutSeconds: sessionTimeoutSeconds)
        let wsURL = URL(string: "wss://messaging.poly.ai/ws")!
        let connService = ConnectionService(transport: connection, wsBaseURL: wsURL, logger: logger)
        let chat = ChatService(logger: logger)
        let heartbeat = HeartbeatService(intervalSeconds: 30)
        let coordinator = Coordinator(
            sessionService: session, connectionService: connService,
            chatService: chat, heartbeatService: heartbeat, logger: logger
        )
        return (coordinator, api, connection)
    }

    // MARK: - Poll-until helpers (no fixed "hope it happened" sleeps)

    /// Polls `condition` until it returns true or the deadline passes; returns whether it was met.
    @discardableResult
    private func waitUntil(
        timeoutMs: UInt64 = 5000,
        pollMs: UInt64 = 20,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
        return await condition()
    }

    /// Polls coordinator.connectionStatus until `.open` arrives, or times out.
    /// connectionStatus replays its last value, so each subscribe() delivers the current status.
    private func waitForOpen(_ coordinator: Coordinator, timeoutMs: UInt64 = 5000) async {
        await waitUntil(timeoutMs: timeoutMs) {
            for await status in coordinator.connectionStatus.subscribe() {
                if case .open = status { return true }
                return false
            }
            return false
        }
    }

    /// Thread-safe collector for events drained on a background Task, so the
    /// test thread and collector never share mutable state unsynchronised.
    private actor EventLog {
        private(set) var deliveredTexts: [String] = []
        private(set) var sawProbe = false
        func record(_ text: String) {
            if text == "__attach_probe__" { sawProbe = true; return }
            deliveredTexts.append(text)
        }
        func count(of text: String) -> Int { deliveredTexts.filter { $0 == text }.count }
        func attached() -> Bool { sawProbe }
    }

    // MARK: - 1. Repeated handshake failures don't stack observation tasks

    /// A handshake failure is a close before open with a code not in
    /// 1000/4000/4001/4003; it routes to the invalid-session refetch+reconnect
    /// path. startObserving() tears down prior observation tasks on each
    /// reconnect, so after several cycles one frame must surface exactly once —
    /// a stacked observer set would duplicate it.
    func testHandshakeFailureRepeatedDoesNotStackTasks() async throws {
        let (coordinator, api, connection) = await makeCoordinator()
        try await coordinator.start()

        let connectedOnce = await waitUntil { connection.connectCalls.count == 1 }
        XCTAssertTrue(connectedOnce,
                      "start() must connect exactly once; got \(connection.connectCalls.count)")
        let createdOnce = await waitUntil { api.createSessionCallCount == 1 }
        XCTAssertTrue(createdOnce,
                      "start() must create exactly one session; got \(api.createSessionCallCount)")

        // Never simulateOpen, so currentAttemptOpened stays false and each 1006
        // is classified as a handshake failure → invalid-session refetch path.
        // Stay within the budget of 3, polling each cycle's reconnect before the
        // next close so the chain is deterministic without a fixed grace window.
        // Reconnect backoff is jittered exponential (~1s, ~2s, ~4.8s per cycle,
        // wall-clock), so the per-cycle waits use a generous timeout that clears
        // the worst-case backoff on a slow/contended CI runner; waitUntil polls
        // and returns the instant the count lands, so healthy runs stay fast.
        let cyclesWithinBudget = 3
        for cycle in 1...cyclesWithinBudget {
            connection.simulateClose(code: 1006, reason: "handshake timeout", wasClean: false)
            let reconnected = await waitUntil(timeoutMs: 20000) { connection.connectCalls.count == 1 + cycle }
            XCTAssertTrue(reconnected,
                          "handshake-failure cycle \(cycle) must reconnect exactly once; got \(connection.connectCalls.count)")
            let refetched = await waitUntil(timeoutMs: 20000) { api.createSessionCallCount == 1 + cycle }
            XCTAssertTrue(refetched,
                          "handshake-failure cycle \(cycle) must refetch a fresh session; got \(api.createSessionCallCount)")
        }

        XCTAssertEqual(api.createSessionCallCount, 1 + cyclesWithinBudget,
                       "each handshake failure within budget refetches a fresh session")
        XCTAssertEqual(connection.connectCalls.count, 1 + cyclesWithinBudget,
                       "each handshake failure within budget reconnects exactly once — no stacked reconnects")

        connection.simulateOpen()
        await waitForOpen(coordinator)

        // coordinator.events is a NON-replay Multicaster: a send before the
        // subscription attaches is lost, so attach the collector and confirm
        // attachment with a probe frame before sending the real one.
        let log = EventLog()
        let collector = Task {
            for await event in coordinator.events.subscribe() {
                if case .agentMessage(_, let p) = event {
                    await log.record(p.text)
                }
            }
        }

        // Re-send the probe each poll: until the continuation is registered the
        // emit is dropped; once `sawProbe` flips, subsequent emits are observed.
        let attached = await waitUntil { () async -> Bool in
            connection.simulateMessage(.agentMessage(
                makeEnvelope(id: "evt_probe", sequence: 1),
                makeAgentMessagePayload(messageId: "m_probe", text: "__attach_probe__")
            ))
            return await log.attached()
        }
        XCTAssertTrue(attached, "events collector must attach before the real frame is sent")

        connection.simulateMessage(.agentMessage(
            makeEnvelope(id: "evt_single", sequence: 99),
            makeAgentMessagePayload(messageId: "m_single", text: "single")
        ))

        let surfaced = await waitUntil { await log.count(of: "single") == 1 }
        XCTAssertTrue(surfaced, "the single frame must surface exactly once")
        // Drain past first delivery so any stacked duplicate observers would have re-delivered.
        _ = await waitUntil(timeoutMs: 300) { await log.count(of: "single") > 1 }
        collector.cancel()

        let finalCount = await log.count(of: "single")
        XCTAssertEqual(finalCount, 1,
                       "after repeated handshake-failure reconnects, one frame must surface once — stacked observation tasks would duplicate it")

        await coordinator.destroy()
    }

    // MARK: - 2. Invalid-session refetch chain exhaustion (bounded, terminal)

    /// An unbroken chain of 4001 closes is capped by maxInvalidSessionAttempts
    /// (3). Because the socket never re-opens between closes, the counter is
    /// preserved across the chain, so the 4th 4001 hits the
    /// routeToInvalidSession() guard and emits terminal `.failed`.
    func testInvalidSessionRefetchChainExhaustion() async throws {
        let (coordinator, api, connection) = await makeCoordinator()

        // Attach the `.failed` watcher before triggering anything so the transition is caught deterministically.
        let failedExp = expectation(description: "terminal .failed reached")
        failedExp.assertForOverFulfill = false
        let failedTask = Task {
            for await status in coordinator.connectionStatus.subscribe() {
                if case .failed = status { failedExp.fulfill(); break }
            }
        }

        try await coordinator.start()
        let connectedOnce = await waitUntil { connection.connectCalls.count == 1 }
        XCTAssertTrue(connectedOnce,
                      "start() must connect once; got \(connection.connectCalls.count)")
        connection.simulateOpen()
        await waitForOpen(coordinator)
        XCTAssertEqual(api.createSessionCallCount, 1, "one session created at start")

        // Three in-budget 4001s. No simulateOpen after this point, so handleOpen()
        // never resets the counter and it accumulates across the chain. Wait for
        // each reconnect before the next close to keep the chain deterministic.
        // Generous per-cycle timeout for the same jittered exponential backoff
        // reason as the test above (~1s/2s/4.8s per cycle, wall-clock).
        for cycle in 1...3 {
            connection.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
            let reconnected = await waitUntil(timeoutMs: 20000) { connection.connectCalls.count == 1 + cycle }
            XCTAssertTrue(reconnected,
                          "in-budget 4001 cycle \(cycle) must reconnect once; got \(connection.connectCalls.count)")
            let refetched = await waitUntil(timeoutMs: 20000) { api.createSessionCallCount == 1 + cycle }
            XCTAssertTrue(refetched,
                          "in-budget 4001 cycle \(cycle) must refetch a fresh session; got \(api.createSessionCallCount)")
        }

        XCTAssertEqual(api.createSessionCallCount, 4,
                       "three in-budget 4001s each refetch a fresh session")
        XCTAssertEqual(connection.connectCalls.count, 4,
                       "three in-budget 4001s each reconnect once")

        // The 4th 4001 exceeds maxInvalidSessionAttempts → terminal `.failed`, not another refetch.
        connection.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
        await fulfillment(of: [failedExp], timeout: 5.0)
        failedTask.cancel()

        // Confirm the negative by polling for a would-be further connect that must never appear.
        let leaked = await waitUntil(timeoutMs: 500) {
            connection.connectCalls.count > 4 || api.createSessionCallCount > 4
        }
        XCTAssertFalse(leaked,
                       "the exhausted invalid-session chain must be terminal — no further refetch/reconnect")
        XCTAssertEqual(api.createSessionCallCount, 4,
                       "the 4th invalid-session must NOT trigger a further refetch — chain is terminal")
        XCTAssertEqual(connection.connectCalls.count, 4,
                       "the 4th invalid-session must NOT trigger a further reconnect")

        await coordinator.destroy()
    }
}