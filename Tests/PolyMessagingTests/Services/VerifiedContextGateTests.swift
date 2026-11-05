// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// The agent-join gate: `Coordinator` holds `REQUEST_POLY_AGENT_JOIN` until the
/// verified-context step resolves.
final class VerifiedContextGateTests: XCTestCase {

    private func makeCoordinator(
        handler: VerifiedContextHandler?,
        api: MockRestApi = MockRestApi()
    ) -> (Coordinator, MockRestApi, MockConnection) {
        SessionStore(apiKey: "test_token").clear()

        let connection = MockConnection()
        let config = Configuration(apiKey: "test_token", environment: .us)
        let logger = NoopLogger()

        let coordinator = Coordinator(
            sessionService: SessionService(api: api, config: config, logger: logger),
            connectionService: ConnectionService(
                transport: connection, wsBaseURL: URL(string: "wss://messaging.poly.ai/ws")!, logger: logger
            ),
            chatService: ChatService(logger: logger),
            heartbeatService: HeartbeatService(intervalSeconds: 30),
            verifiedContextService: handler.map {
                VerifiedContextService(handler: $0, api: api, logger: logger)
            },
            logger: logger
        )
        return (coordinator, api, connection)
    }

    private func startAndOpen(_ coordinator: Coordinator, _ connection: MockConnection) async throws {
        try await coordinator.start()
        await waitForTransportSubscriptions(connection, after: (0, 0, 0))
        connection.simulateOpen()
        await waitForOpen(coordinator)
    }

    private typealias Subscriptions = (open: Int, messages: Int, batches: Int)

    private func subscriptions(_ connection: MockConnection) -> Subscriptions {
        (connection.openSubscriptions, connection.messageSubscriptions, connection.batchSubscriptions)
    }

    /// Events emitted before ConnectionService subscribes are dropped, so wait
    /// until it has (re)subscribed to every stream the test uses.
    private func waitForTransportSubscriptions(_ connection: MockConnection, after previous: Subscriptions) async {
        await waitUntil {
            connection.openSubscriptions > previous.open
                && connection.messageSubscriptions > previous.messages
                && connection.batchSubscriptions > previous.batches
        }
    }

    /// subscribe() replays the current status — re-check until it's `.open`.
    private func waitForOpen(_ coordinator: Coordinator, timeoutMs: UInt64 = 8000) async {
        let deadlineNs = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadlineNs {
            for await status in coordinator.connectionStatus.subscribe() {
                if case .open = status { return }
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func joinCount(_ connection: MockConnection) -> Int {
        connection.sentEvents.filter {
            if case .requestPolyAgentJoin = $0 { return true }
            return false
        }.count
    }

    private func sessionStart(_ contextId: String?, id: String = "evt_1") -> MessagingEvent {
        .sessionStart(makeEnvelope(id: id), makeSessionStartPayload(contextId: contextId))
    }

    func testJoinWaitsForTokenSubmit() async throws {
        let recorder = HandlerRecorder()
        let latch = Latch()
        let (coordinator, api, connection) = makeCoordinator { req in
            await recorder.record(req)
            await latch.wait()
            return "signed.jwt.token"
        }
        let events = coordinator.events.subscribe()
        try await startAndOpen(coordinator, connection)

        connection.simulateMessage(sessionStart("ctx_abc"))
        await waitUntil { await recorder.requests.count == 1 }
        XCTAssertEqual(joinCount(connection), 0, "Join must be held while the handler runs")

        await latch.open()
        await waitUntil { self.joinCount(connection) == 1 }
        XCTAssertEqual(joinCount(connection), 1)
        XCTAssertEqual(api.submittedContexts.first?.token, "signed.jwt.token")
        let requests = await recorder.requests
        XCTAssertEqual(requests, [VerifiedContextRequest(sessionId: "session_123", contextId: "ctx_abc")])

        var statuses: [VerifiedContextStatus] = []
        for await event in events {
            if case .verifiedContext(let s) = event { statuses.append(s) }
            if statuses.count == 2 { break }
        }
        XCTAssertEqual(statuses, [.pending, .set])
    }

    func testFailedSubmitStillSendsJoin() async throws {
        let api = MockRestApi()
        api.submitContextResult = .failure(PolyError.verifiedContext(.verificationFailed("invalid token signature")))
        let (coordinator, _, connection) = makeCoordinator(handler: { _ in "bad.sig.token" }, api: api)
        try await startAndOpen(coordinator, connection)

        connection.simulateMessage(sessionStart("ctx_abc"))

        let joined = await waitUntil { self.joinCount(connection) == 1 }
        XCTAssertTrue(joined)
    }

    func testNoContextIdSkipsHandler() async throws {
        let recorder = HandlerRecorder()
        let (coordinator, api, connection) = makeCoordinator { req in
            await recorder.record(req)
            return "signed.jwt.token"
        }
        try await startAndOpen(coordinator, connection)

        connection.simulateMessage(sessionStart(nil))
        await waitUntil { self.joinCount(connection) == 1 }

        XCTAssertEqual(joinCount(connection), 1)
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(api.submittedContexts.isEmpty)
    }

    func testRepeatSessionStartDoesNotAskAgain() async throws {
        let recorder = HandlerRecorder()
        let (coordinator, _, connection) = makeCoordinator { req in
            await recorder.record(req)
            return "signed.jwt.token"
        }
        let events = coordinator.events.subscribe()
        try await startAndOpen(coordinator, connection)

        connection.simulateMessage(sessionStart("ctx_abc"))
        await waitUntil { self.joinCount(connection) == 1 }
        // Reconnect on the same session replays SESSION_START.
        connection.simulateMessage(sessionStart("ctx_abc", id: "evt_2"))
        var starts = 0
        for await event in events {
            if case .sessionStart = event { starts += 1 }
            if starts == 2 { break }
        }

        XCTAssertEqual(joinCount(connection), 1)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testStaleJoinIsDroppedWhenSessionChangesMidRequest() async throws {
        let latch = Latch()
        let (coordinator, api, connection) = makeCoordinator { _ in
            await latch.wait()
            return "signed.jwt.token"
        }
        try await startAndOpen(coordinator, connection)

        connection.simulateMessage(sessionStart("ctx_old"))
        await waitUntil { await coordinator.hasVerifiedContextInFlight }

        // Start New Chat while the handler is still signing for the old session.
        api.createSessionResult = .success(SessionCreated(sessionId: "session_456"))
        await coordinator.startNewSession()
        await latch.open()
        await waitUntil { await !coordinator.hasVerifiedContextInFlight }

        XCTAssertEqual(api.submittedContexts.count, 1)
        XCTAssertEqual(joinCount(connection), 0, "Old session's join must not reach the new socket")
    }

    // MARK: - refreshVerifiedContext

    func testRefreshResignsAndSubmitsWithNotifyAgent() async throws {
        let recorder = HandlerRecorder()
        let (coordinator, api, connection) = makeCoordinator { req in
            await recorder.record(req)
            return "signed.jwt.token"
        }
        let events = coordinator.events.subscribe()
        try await startAndOpen(coordinator, connection)
        connection.simulateMessage(sessionStart("ctx_abc"))
        await waitUntil { self.joinCount(connection) == 1 }

        await coordinator.refreshVerifiedContext(notifyAgent: true)

        let requests = await recorder.requests
        XCTAssertEqual(requests, Array(repeating: VerifiedContextRequest(sessionId: "session_123", contextId: "ctx_abc"), count: 2))
        XCTAssertEqual(api.submittedContexts.map(\.notifyAgent), [false, true])
        XCTAssertEqual(joinCount(connection), 1, "A refresh must not send another agent join")

        var statuses: [VerifiedContextStatus] = []
        for await event in events {
            if case .verifiedContext(let s) = event { statuses.append(s) }
            if statuses.count == 4 { break }
        }
        XCTAssertEqual(statuses, [.pending, .set, .pending, .set])
    }

    func testRefreshBeforeSessionStartIsIgnored() async throws {
        let recorder = HandlerRecorder()
        let (coordinator, api, _) = makeCoordinator { req in
            await recorder.record(req)
            return "signed.jwt.token"
        }
        try await coordinator.start()

        await coordinator.refreshVerifiedContext(notifyAgent: false)

        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(api.submittedContexts.isEmpty)
    }

    func testRefreshWithoutHandlerIsIgnored() async throws {
        let (coordinator, api, connection) = makeCoordinator(handler: nil)
        try await startAndOpen(coordinator, connection)
        connection.simulateMessage(sessionStart("ctx_abc"))
        await waitUntil { self.joinCount(connection) == 1 }

        await coordinator.refreshVerifiedContext(notifyAgent: true)

        XCTAssertTrue(api.submittedContexts.isEmpty)
    }

    func testRefreshDuringFreshSessionRequestIsDropped() async throws {
        let recorder = HandlerRecorder()
        let latch = Latch()
        let (coordinator, _, connection) = makeCoordinator { req in
            await recorder.record(req)
            await latch.wait()
            return "signed.jwt.token"
        }
        try await startAndOpen(coordinator, connection)
        connection.simulateMessage(sessionStart("ctx_abc"))
        await waitUntil { await recorder.requests.count == 1 }

        // The fresh-session gate is still waiting on the handler.
        await coordinator.refreshVerifiedContext(notifyAgent: false)
        await latch.open()
        await waitUntil { self.joinCount(connection) == 1 }

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1, "An overlapping refresh is dropped, not queued")
        XCTAssertEqual(joinCount(connection), 1)
    }

    func testOldGateFinishingLateDoesNotUnblockRefreshForNewSession() async throws {
        let recorder = HandlerRecorder()
        let oldLatch = Latch()
        let newLatch = Latch()
        let (coordinator, api, connection) = makeCoordinator { req in
            await recorder.record(req)
            switch req.contextId {
            case "ctx_old": await oldLatch.wait()
            case "ctx_new": await newLatch.wait()
            default: break
            }
            return "signed.jwt.token"
        }
        try await startAndOpen(coordinator, connection)

        // Session A's gate blocks the single-message path...
        connection.simulateMessage(sessionStart("ctx_old"))
        await waitUntil { await recorder.requests.count == 1 }

        // ...so session B's SESSION_START arrives on the batch path and its gate starts too.
        let before = subscriptions(connection)
        api.createSessionResult = .success(SessionCreated(sessionId: "session_456"))
        await coordinator.startNewSession()
        await waitForTransportSubscriptions(connection, after: before)
        connection.batchCaster.emit([sessionStart("ctx_new", id: "evt_2")])
        await waitUntil { await recorder.requests.count == 2 }

        // A finishes while B is still in flight; a refresh now must not overlap B.
        await oldLatch.open()
        await waitUntil { api.submittedContexts.count == 1 }
        await coordinator.refreshVerifiedContext(notifyAgent: false)

        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.contextId), ["ctx_old", "ctx_new"], "Refresh overlapped session B's gate")

        await newLatch.open()
        await waitUntil { self.joinCount(connection) == 1 }
        XCTAssertEqual(joinCount(connection), 1)
    }

    func testRefreshAfterSessionChangeIgnoresOldContextId() async throws {
        let recorder = HandlerRecorder()
        let (coordinator, api, connection) = makeCoordinator { req in
            await recorder.record(req)
            return "signed.jwt.token"
        }
        try await startAndOpen(coordinator, connection)
        connection.simulateMessage(sessionStart("ctx_old"))
        await waitUntil { self.joinCount(connection) == 1 }

        // New session, but its SESSION_START (and context_id) hasn't arrived yet.
        api.createSessionResult = .success(SessionCreated(sessionId: "session_456"))
        await coordinator.startNewSession()
        await coordinator.refreshVerifiedContext(notifyAgent: false)

        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.contextId), ["ctx_old"], "Must not re-sign the previous session's context_id")
    }
}
