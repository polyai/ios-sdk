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

    /// Polls coordinator.connectionStatus until `.open` arrives, or times out.
    /// connectionStatus replays its last value, so each fresh subscribe()
    /// delivers the current status immediately.
    private func waitForOpen(_ coordinator: Coordinator, timeoutMs: UInt64 = 8000) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            for await status in coordinator.connectionStatus.subscribe() {
                if case .open = status { return }
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
        try? await Task.sleep(nanoseconds: 150_000_000) // let observation tasks attach

        // Drive several handshake-failure → refetch → reconnect cycles. We
        // never simulateOpen here, so each new attempt's currentAttemptOpened
        // stays false and the next 1006 is classified as a handshake failure
        // (close before open, code not 1000/4000/4001/4003). The invalid-
        // session refetch budget is 3, so cycle exactly within budget.
        let cyclesWithinBudget = 3
        for _ in 0..<cyclesWithinBudget {
            connection.simulateClose(code: 1006, reason: "handshake timeout", wasClean: false)
            // refetch debounce (300ms) + createSession + reconnect.
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // Each cycle: invalidSession → handleInvalidSession → refetchSession
        // (a fresh createSession) → connectToSession. createSession was called
        // once at start + once per cycle.
        XCTAssertEqual(api.createSessionCallCount, 1 + cyclesWithinBudget,
                       "each handshake failure within budget refetches a fresh session")
        // start() connects once; each cycle reconnects once — no stacking.
        XCTAssertEqual(connection.connectCalls.count, 1 + cyclesWithinBudget,
                       "each handshake failure within budget reconnects exactly once — no stacked reconnects")

        // Now let the latest attempt actually open and deliver ONE message.
        connection.simulateOpen()
        await waitForOpen(coordinator)

        var delivered = 0
        let exp = expectation(description: "agent message delivered")
        exp.assertForOverFulfill = false
        let task = Task {
            for await event in coordinator.events.subscribe() {
                if case .agentMessage(_, let p) = event, p.text == "single" {
                    delivered += 1
                    exp.fulfill()
                }
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000) // let the subscriber attach

        connection.simulateMessage(.agentMessage(
            makeEnvelope(id: "evt_single", sequence: 99),
            makeAgentMessagePayload(messageId: "m_single", text: "single")
        ))

        await fulfillment(of: [exp], timeout: 3.0)
        // Give any *stacked* duplicate observers a chance to (wrongly) re-deliver.
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        XCTAssertEqual(delivered, 1,
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

        // Watch for the terminal `.failed` status on the public stream.
        let failedExp = expectation(description: "terminal .failed reached")
        failedExp.assertForOverFulfill = false
        let failedTask = Task {
            for await status in coordinator.connectionStatus.subscribe() {
                if case .failed = status { failedExp.fulfill(); break }
            }
        }

        try await coordinator.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        connection.simulateOpen()
        await waitForOpen(coordinator)
        XCTAssertEqual(api.createSessionCallCount, 1, "one session created at start")

        // Three 4001s that DO refetch+reconnect (budget 1, 2, 3). We never
        // simulateOpen after this point, so the invalid-session counter is
        // never reset by handleOpen() and accumulates across the chain.
        for _ in 0..<3 {
            connection.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
            try? await Task.sleep(nanoseconds: 700_000_000) // refetch debounce + reconnect
        }

        // start (1) + 3 refetches = 4 createSession calls; 4 connects total.
        XCTAssertEqual(api.createSessionCallCount, 4,
                       "three in-budget 4001s each refetch a fresh session")
        XCTAssertEqual(connection.connectCalls.count, 4,
                       "three in-budget 4001s each reconnect once")

        // The 4th 4001 exceeds maxInvalidSessionAttempts → terminal `.failed`,
        // NOT another refetch.
        connection.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
        await fulfillment(of: [failedExp], timeout: 4.0)
        failedTask.cancel()

        // Let any (wrongful) further refetch settle.
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(api.createSessionCallCount, 4,
                       "the 4th invalid-session must NOT trigger a further refetch — chain is terminal")
        XCTAssertEqual(connection.connectCalls.count, 4,
                       "the 4th invalid-session must NOT trigger a further reconnect")

        // Final published status is terminal `.failed`.
        var sawFailed = false
        for await status in coordinator.connectionStatus.subscribe() {
            if case .failed = status { sawFailed = true }
            break
        }
        XCTAssertTrue(sawFailed, "exhausted invalid-session chain ends in terminal .failed")

        await coordinator.destroy()
    }
}
