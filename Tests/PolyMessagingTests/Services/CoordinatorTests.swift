import XCTest
@testable import PolyMessaging

final class CoordinatorTests: XCTestCase {

    private func makeCoordinator() async -> (Coordinator, MockRestApi, MockConnection) {
        // SessionStore persists in UserDefaults; clear the token-namespaced
        // entry so tests don't see a stored session from a prior test run
        // (which would short-circuit resume() and skip createSession).
        SessionStore(connectorToken: "test_token").clear()

        let api = MockRestApi()
        let connection = MockConnection()
        let config = Configuration(connectorToken: "test_token", environment: .dev)
        let logger = NoopLogger()

        let session = SessionService(api: api, config: config, logger: logger)
        let wsURL = URL(string: "wss://messaging.dev.poly.ai/ws")!
        let connService = ConnectionService(transport: connection, wsBaseURL: wsURL, logger: logger)
        let chat = ChatService(logger: logger)
        let heartbeat = HeartbeatService(intervalSeconds: 30)

        let coordinator = Coordinator(
            sessionService: session,
            connectionService: connService,
            chatService: chat,
            heartbeatService: heartbeat,
            logger: logger
        )

        return (coordinator, api, connection)
    }

    // MARK: - Start

    func testStartCreatesSessionAndConnects() async throws {
        let (coordinator, api, connection) = await makeCoordinator()
        try await coordinator.start()

        let tokenCalls = api.obtainTokenCallCount
        let sessionCalls = api.createSessionCallCount
        XCTAssertEqual(tokenCalls, 1)
        XCTAssertEqual(sessionCalls, 1)
        XCTAssertEqual(connection.connectCalls.count, 1)
    }

    func testStartIsIdempotent() async throws {
        let (coordinator, api, _) = await makeCoordinator()
        try await coordinator.start()
        try await coordinator.start()

        let calls = api.createSessionCallCount
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Send

    func testSendForwardsToConnection() async throws {
        let (coordinator, _, connection) = await makeCoordinator()
        try await coordinator.start()

        try await coordinator.send("Hello")

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(connection.sentEvents.count, 1)
        if case .userMessage(let text, _) = connection.sentEvents.first {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected userMessage")
        }
    }

    // MARK: - End

    func testEndSendsEndConversationAndDisconnects() async throws {
        let (coordinator, _, connection) = await makeCoordinator()
        try await coordinator.start()
        // Let ConnectionService's transport.openEvents subscriber attach
        // before emitting — otherwise the open event hits zero continuations
        // (openCaster has no replay) and the state never becomes .open.
        // Matches the pattern in testConnectionOpenEmitsConnected (line 141).
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Mirror real-world: end() only sends UserEndConversation when the
        // socket is actually open. Without simulating open, the new
        // (web-parity) end() path takes the "WS closed" branch and emits a
        // disconnect error instead.
        connection.simulateOpen()
        await waitForOpen(coordinator)

        await coordinator.end()

        let endEvents = connection.sentEvents.filter {
            if case .userEndConversation = $0 { return true }
            return false
        }
        XCTAssertEqual(endEvents.count, 1)
        XCTAssertEqual(connection.disconnectCalls.count, 1)
    }

    /// Polls coordinator.connectionStatus until .open arrives, or times out.
    /// connectionStatus is a replay-last-value Multicaster, so each fresh
    /// subscribe() delivers the current status immediately — we just need to
    /// keep checking until we see .open or hit the deadline.
    private func waitForOpen(_ coordinator: Coordinator, timeoutMs: UInt64 = 8000) async {
        let deadlineNs = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadlineNs {
            for await status in coordinator.connectionStatus.subscribe() {
                if case .open = status { return }
                break  // only check the replayed value, then re-subscribe
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Destroy

    func testDestroyCleanup() async throws {
        let (coordinator, _, _) = await makeCoordinator()
        try await coordinator.start()
        await coordinator.destroy()
        // Should not crash; all tasks cancelled, multicasters finished
    }

    // MARK: - Connection open emits connected

    func testConnectionOpenEmitsConnected() async throws {
        let (coordinator, _, connection) = await makeCoordinator()

        // Subscribe BEFORE start so we don't miss events
        let expectation = XCTestExpectation(description: "connected emitted")
        let task = Task {
            for await event in coordinator.events.subscribe() {
                if case .connected = event {
                    expectation.fulfill()
                    break
                }
            }
        }

        try await coordinator.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        connection.simulateOpen()
        await fulfillment(of: [expectation], timeout: 3.0)
        task.cancel()
    }

    // MARK: - Incoming message forwarded

    func testIncomingAgentMessageForwarded() async throws {
        let (coordinator, _, connection) = await makeCoordinator()
        try await coordinator.start()

        let expectation = XCTestExpectation(description: "agent message forwarded")
        let task = Task {
            for await event in coordinator.events.subscribe() {
                if case .agentMessage = event {
                    expectation.fulfill()
                    break
                }
            }
        }

        connection.simulateOpen()
        try? await Task.sleep(nanoseconds: 100_000_000)

        connection.simulateMessage(.agentMessage(
            makeEnvelope(),
            makeAgentMessagePayload(text: "Hi from agent")
        ))

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
    }

    // MARK: - Session start triggers agent join

    func testSessionStartTriggersRequestPolyAgentJoin() async throws {
        let (coordinator, _, connection) = await makeCoordinator()
        try await coordinator.start()
        connection.simulateOpen()

        try? await Task.sleep(nanoseconds: 100_000_000)

        connection.simulateMessage(.sessionStart(
            makeEnvelope(), makeSessionStartPayload()
        ))

        try? await Task.sleep(nanoseconds: 300_000_000)

        let joinEvents = connection.sentEvents.filter {
            if case .requestPolyAgentJoin = $0 { return true }
            return false
        }
        XCTAssertEqual(joinEvents.count, 1)
    }

    // MARK: - Start New Chat triggers fresh agent join

    func testStartNewSessionTriggersRequestPolyAgentJoinOnNewSession() async throws {
        let (coordinator, _, connection) = await makeCoordinator()
        try await coordinator.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        connection.simulateOpen()
        await waitForOpen(coordinator)

        // First session: SESSION_START → 1 RequestPolyAgentJoin
        connection.simulateMessage(.sessionStart(
            makeEnvelope(), makeSessionStartPayload()
        ))
        try? await Task.sleep(nanoseconds: 300_000_000)

        let firstCount = connection.sentEvents.filter {
            if case .requestPolyAgentJoin = $0 { return true }
            return false
        }.count
        XCTAssertEqual(firstCount, 1, "Initial SESSION_START should trigger 1 join request")

        // Start a fresh chat — sends end + refetches + reconnects
        await coordinator.startNewSession()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(connection.connectCalls.count, 2, "startNewSession should reconnect")

        // New socket opens and emits a fresh SESSION_START
        connection.simulateOpen()
        await waitForOpen(coordinator)
        connection.simulateMessage(.sessionStart(
            makeEnvelope(id: "evt_2"), makeSessionStartPayload()
        ))
        try? await Task.sleep(nanoseconds: 300_000_000)

        let totalRequests = connection.sentEvents.filter {
            if case .requestPolyAgentJoin = $0 { return true }
            return false
        }.count
        XCTAssertEqual(totalRequests, 2, "startNewSession followed by fresh SESSION_START should send another join request")
    }
}
