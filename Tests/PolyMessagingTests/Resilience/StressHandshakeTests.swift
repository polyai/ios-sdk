// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress / robustness probes for the handshake + invalid-session path.
///
/// These drive the real Coordinator → ConnectionService → SessionService graph
/// through MockConnection / MockRestApi so every scenario is deterministic.
/// They focus on two failure-mode invariants:
///
///  1. Repeated handshake failures (close-before-open with a reconnectable
///     code) must not stack observation tasks. ConnectionService.startObserving
///     cancels the prior task set on every (re)connect, so the surface proxy is
///     that a single inbound frame is still delivered exactly once after many
///     reconnect cycles — duplicated delivery would prove stacked observers.
///
///  2. The invalid-session refetch chain is bounded by
///     ConnectionService.maxInvalidSessionAttempts (3). The 4th 4001 /
///     invalid-session in an unbroken chain must terminate in `.failed`, not
///     loop refetching forever.
///
/// Timing note: the SDK's reconnect backoff is jittered exponential
/// (`pow(2,n) * random(0.8...1.2)`) so we never assert *when* a reconnect
/// fires. We only assert invariants that hold regardless of scheduling
/// (createSession / connect counts within the documented budgets, and which
/// terminal status is/ isn't reached), and we reach those assertions via
/// poll-until-condition waits rather than fixed sleeps.
final class StressHandshakeTests: XCTestCase {

    // MARK: - Builders (mirror ResilienceMatrixTests)

    private func makeCoordinator(
        sessionTimeoutSeconds: TimeInterval = 3600
    ) async -> (Coordinator, MockRestApi, MockConnection) {
        // SessionStore persists in UserDefaults; clear the token-namespaced
        // entry so a stored session from a prior test run doesn't short-circuit
        // resume() and skip createSession.
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

    /// Polls `condition` every ~20ms until it returns true or the deadline
    /// passes. Returns whether the condition was met. Used in place of fixed
    /// Task.sleep grace periods so the test reacts to the real state change
    /// instead of racing it.
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
    /// connectionStatus replays its last value, so each fresh subscribe()
    /// delivers the current status immediately.
    private func waitForOpen(_ coordinator: Coordinator, timeoutMs: UInt64 = 5000) async {
        await waitUntil(timeoutMs: timeoutMs) {
            for await status in coordinator.connectionStatus.subscribe() {
                if case .open = status { return true }
                return false
            }
            return false
        }
    }

    /// Thread-safe collector for events observed on the (background) Task that
    /// drains a non-replay Multicaster, so the test thread and the collector
    /// Task never touch shared mutable state without synchronisation.
    /// Mirrors the StatusLog actor pattern in StressReconnectStormTests.
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

    /// A handshake failure is a close BEFORE the socket ever opened, with a
    /// code that isn't 1000/4000/4001/4003. ConnectionService routes that to
    /// the invalid-session path, which (via the Coordinator) refetches and
    /// reconnects. After several such cycles a single inbound message must
    /// still be delivered EXACTLY once: ConnectionService.startObserving()
    /// tears down the previous transport-observation tasks on each reconnect,
    /// so a stacked observer set would surface the frame multiple times.
    func testHandshakeFailureRepeatedDoesNotStackTasks() async throws {
        let (coordinator, api, connection) = await makeCoordinator()
        try await coordinator.start()

        // start() connected exactly once; wait for that rather than sleeping.
        let connectedOnce = await waitUntil { connection.connectCalls.count == 1 }
        XCTAssertTrue(connectedOnce,
                      "start() must connect exactly once; got \(connection.connectCalls.count)")
        let createdOnce = await waitUntil { api.createSessionCallCount == 1 }
        XCTAssertTrue(createdOnce,
                      "start() must create exactly one session; got \(api.createSessionCallCount)")

        // Drive several handshake-failure → refetch → reconnect cycles. We
        // never simulateOpen here, so each new attempt's currentAttemptOpened
        // stays false and the next 1006 is classified as a handshake failure
        // (close before open, code not 1000/4000/4001/4003). The invalid-
        // session refetch budget is 3, so cycle exactly within budget. Each
        // close kicks off an async refetch+reconnect; we poll for the connect
        // count to settle for THAT cycle before issuing the next close, so the
        // chain stays deterministic without relying on a fixed grace window.
        let cyclesWithinBudget = 3
        for cycle in 1...cyclesWithinBudget {
            connection.simulateClose(code: 1006, reason: "handshake timeout", wasClean: false)
            // Each handshake failure: invalidSession → handleInvalidSession →
            // refetchSession (a fresh createSession) → connectToSession.
            let reconnected = await waitUntil { connection.connectCalls.count == 1 + cycle }
            XCTAssertTrue(reconnected,
                          "handshake-failure cycle \(cycle) must reconnect exactly once; got \(connection.connectCalls.count)")
            let refetched = await waitUntil { api.createSessionCallCount == 1 + cycle }
            XCTAssertTrue(refetched,
                          "handshake-failure cycle \(cycle) must refetch a fresh session; got \(api.createSessionCallCount)")
        }

        // createSession was called once at start + once per cycle; one connect
        // per cycle, no stacking.
        XCTAssertEqual(api.createSessionCallCount, 1 + cyclesWithinBudget,
                       "each handshake failure within budget refetches a fresh session")
        XCTAssertEqual(connection.connectCalls.count, 1 + cyclesWithinBudget,
                       "each handshake failure within budget reconnects exactly once — no stacked reconnects")

        // Now let the latest attempt actually open and deliver ONE message.
        connection.simulateOpen()
        await waitForOpen(coordinator)

        // coordinator.events is a NON-replay Multicaster: a send before the
        // subscription attaches is lost. So attach the collector first, then
        // CONFIRM attachment with a probe frame before sending the real one —
        // never rely on a sleep to "let the subscriber attach".
        let log = EventLog()
        let collector = Task {
            for await event in coordinator.events.subscribe() {
                if case .agentMessage(_, let p) = event {
                    await log.record(p.text)
                }
            }
        }

        // Probe until the collector loop has actually attached to the stream.
        // We re-send the probe each poll because, until the continuation is
        // registered, the emit is dropped; once `sawProbe` flips we KNOW any
        // subsequent emit will be observed.
        let attached = await waitUntil { () async -> Bool in
            connection.simulateMessage(.agentMessage(
                makeEnvelope(id: "evt_probe", sequence: 1),
                makeAgentMessagePayload(messageId: "m_probe", text: "__attach_probe__")
            ))
            return await log.attached()
        }
        XCTAssertTrue(attached, "events collector must attach before the real frame is sent")

        // The single real frame. With the collector confirmed attached, this
        // emit cannot be lost.
        connection.simulateMessage(.agentMessage(
            makeEnvelope(id: "evt_single", sequence: 99),
            makeAgentMessagePayload(messageId: "m_single", text: "single")
        ))

        let surfaced = await waitUntil { await log.count(of: "single") == 1 }
        XCTAssertTrue(surfaced, "the single frame must surface exactly once")
        // Drain a little past first delivery so any *stacked* duplicate
        // observers would have re-delivered by now — then re-assert.
        _ = await waitUntil(timeoutMs: 300) { await log.count(of: "single") > 1 }
        collector.cancel()

        let finalCount = await log.count(of: "single")
        XCTAssertEqual(finalCount, 1,
                       "after repeated handshake-failure reconnects, one frame must surface once — stacked observation tasks would duplicate it")

        await coordinator.destroy()
    }

    // MARK: - 2. Invalid-session refetch chain exhaustion (bounded, terminal)

    /// An unbroken chain of 4001 / invalid-session closes is capped by
    /// ConnectionService.maxInvalidSessionAttempts (3). Because the socket
    /// never re-opens between closes (no simulateOpen), the invalid-session
    /// counter is preserved across the refetch chain. The 4th 4001 must hit the
    /// guard in routeToInvalidSession() and emit a terminal `.failed` rather
    /// than refetching forever.
    func testInvalidSessionRefetchChainExhaustion() async throws {
        let (coordinator, api, connection) = await makeCoordinator()

        // Watch for the terminal `.failed` status on the public stream BEFORE
        // we trigger anything. connectionStatus replays its last value, but we
        // want to catch the transition deterministically, so attach first.
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

        // Three 4001s that DO refetch+reconnect (budget 1, 2, 3). We never
        // simulateOpen after this point, so the invalid-session counter is
        // never reset by handleOpen() and accumulates across the chain. Wait
        // for each cycle's reconnect to land before issuing the next close so
        // the chain is deterministic regardless of refetch-debounce timing.
        for cycle in 1...3 {
            connection.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
            let reconnected = await waitUntil { connection.connectCalls.count == 1 + cycle }
            XCTAssertTrue(reconnected,
                          "in-budget 4001 cycle \(cycle) must reconnect once; got \(connection.connectCalls.count)")
            let refetched = await waitUntil { api.createSessionCallCount == 1 + cycle }
            XCTAssertTrue(refetched,
                          "in-budget 4001 cycle \(cycle) must refetch a fresh session; got \(api.createSessionCallCount)")
        }

        // start (1) + 3 refetches = 4 createSession calls; 4 connects total.
        XCTAssertEqual(api.createSessionCallCount, 4,
                       "three in-budget 4001s each refetch a fresh session")
        XCTAssertEqual(connection.connectCalls.count, 4,
                       "three in-budget 4001s each reconnect once")

        // The 4th 4001 exceeds maxInvalidSessionAttempts → terminal `.failed`,
        // NOT another refetch.
        connection.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
        await fulfillment(of: [failedExp], timeout: 5.0)
        failedTask.cancel()

        // The 4th invalid-session must NOT trigger a further refetch/reconnect.
        // Poll for a *would-be* further connect (which must never appear); the
        // negative is confirmed by the count staying pinned at 4 across the
        // window rather than by a fixed settle-sleep.
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