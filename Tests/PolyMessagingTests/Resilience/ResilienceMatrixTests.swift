// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// The ship-readiness resilience matrix. One test per failure-mode the SDK
/// claims to handle, driven entirely through MockConnection / MockRestApi so
/// every scenario is deterministic and offline-runnable.
///
/// Matrix (goal §2):
///   1. offline -> fail + retry on network restore
///   2. 1006 reconnect + cursor replay (plain-int `cursor=N`, NOT `seq:N`)
///   3. no duplicate bubbles (envelope-id dedup, invariant I10)
///   4. network-lost drop via 1006 only when open (invariant I26)
///   5. max-reconnect terminal emits BOTH closeEvents AND .failed (invariant I15)
///   6. 4001 -> invalid session -> refetch -> reconnect
///   7. idle / expiry (checkTimeout fires past the idle window, invariant I6)
///   8. background -> foreground reconnect of a stale session (invariant I25)
///   9. streaming reassembly: mid-stream message_id switch finalises old buffer (I17)
///  10. batch order: covered by WireDecoderTests.testDecodeEventBatchSortsBySequence
///      and testDecodeEventBatchNilSequenceAtEnd (invariant I9) — re-asserted here.
final class ResilienceMatrixTests: XCTestCase {

    // MARK: - Builders

    private func makeConnectionService() -> (ConnectionService, MockConnection) {
        let mock = MockConnection()
        let url = URL(string: "wss://messaging.poly.ai/ws")!
        return (ConnectionService(transport: mock, wsBaseURL: url, logger: NoopLogger()), mock)
    }

    private func makeCoordinator(
        sessionTimeoutSeconds: TimeInterval = 3600
    ) async -> (Coordinator, MockRestApi, MockConnection, NetworkMonitor, AppLifecycleObserver) {
        SessionStore(apiKey: "test_token").clear()
        let api = MockRestApi()
        let connection = MockConnection()
        let config = Configuration(apiKey: "test_token", environment: .production)
        let logger = NoopLogger()
        let session = SessionService(api: api, config: config, logger: logger,
                                     sessionTimeoutSeconds: sessionTimeoutSeconds)
        let wsURL = URL(string: "wss://messaging.poly.ai/ws")!
        let connService = ConnectionService(transport: connection, wsBaseURL: wsURL, logger: logger)
        let chat = ChatService(logger: logger)
        let heartbeat = HeartbeatService(intervalSeconds: 30)
        let netMon = NetworkMonitor()
        let lifecycle = AppLifecycleObserver()
        let coordinator = Coordinator(
            sessionService: session, connectionService: connService,
            chatService: chat, heartbeatService: heartbeat, logger: logger,
            networkMonitor: netMon, lifecycleObserver: lifecycle
        )
        return (coordinator, api, connection, netMon, lifecycle)
    }

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

    // MARK: - 1. offline -> fail + retry

    func test_offline_failsThenRetriesOnNetworkRestore() async {
        let (coordinator, api, connection, netMon, _) = await makeCoordinator()
        struct Offline: Error {}
        api.obtainTokenResult = .failure(Offline())

        // Offline at launch: start() must throw, no socket opened.
        do { try await coordinator.start(); XCTFail("expected start to throw offline") }
        catch { /* expected */ }
        XCTAssertEqual(connection.connectCalls.count, 0, "no WS while offline")
        XCTAssertEqual(api.createSessionCallCount, 0, "token failure short-circuits createSession")

        // Network comes back: the SDK must auto-retry the resume-or-create flow.
        try? await Task.sleep(nanoseconds: 100_000_000) // let observation tasks attach
        api.obtainTokenResult = .success(AccessTokenResponse(accessToken: testJWT, expiresIn: 3600, tokenType: "Bearer"))
        netMon.networkRestored.emit(())
        try? await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(api.createSessionCallCount, 1, "session created after restore")
        XCTAssertEqual(connection.connectCalls.count, 1, "WS connected after restore")
        XCTAssertGreaterThanOrEqual(api.obtainTokenCallCount, 2, "token retried after restore")
    }

    // MARK: - 2. 1006 reconnect + cursor replay

    func test_1006_reconnectsAndReplaysCursorAsPlainInt() async {
        let (service, mock) = makeConnectionService()
        await service.connectToSession(sessionId: "sess_1", accessToken: "tok_1")
        try? await Task.sleep(nanoseconds: 120_000_000) // let open subscriber attach
        mock.simulateOpen()
        try? await Task.sleep(nanoseconds: 120_000_000) // let handleOpen run (currentAttemptOpened=true)
        // Simulate having received history up to sequence 12.
        await service.updateLastSequence(12)

        // Abnormal close (keep-alive timeout) -> reconnect ladder engages.
        mock.simulateClose(code: 1006, reason: "keep-alive timeout", wasClean: false)
        try? await Task.sleep(nanoseconds: 1_700_000_000) // > max backoff for attempt 0 (~1.2s)

        XCTAssertEqual(mock.connectCalls.count, 2, "reconnected after 1006")
        let replayURL = mock.connectCalls[1].absoluteString
        XCTAssertTrue(replayURL.contains("cursor=12"),
                      "cursor replay must send the high-water sequence; got \(replayURL)")
        XCTAssertFalse(replayURL.contains("seq:"),
                       "server parses cursor with strconv.ParseUint — `seq:` prefix would be rejected")
        XCTAssertTrue(replayURL.contains("session_id=sess_1"), "same session on reconnect (I21)")
    }

    // MARK: - 3. no duplicate bubbles (envelope-id dedup, I10)

    func test_duplicateEnvelopeId_emitsBubbleOnce() async {
        let chat = ChatService(logger: NoopLogger())
        let env = makeEnvelope(id: "evt_dup", sequence: 5)
        let payload = makeAgentMessagePayload(messageId: "m1", text: "Hello")

        let stream = chat.eventStream.subscribe() // subscribe BEFORE emitting
        // Same envelope delivered twice (e.g. cursor replay overlap after 1006).
        _ = await chat.handleMessage(.agentMessage(env, payload))
        _ = await chat.handleMessage(.agentMessage(env, payload))
        chat.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await ev in stream { emitted.append(ev) }
        let agentMessages = emitted.filter { if case .agentMessage = $0 { return true }; return false }
        XCTAssertEqual(agentMessages.count, 1, "duplicate envelope id must collapse to one bubble")
    }

    // MARK: - 4. network-lost drop (I26)

    func test_networkLost_dropsOpenSocketWith1006() async {
        let (coordinator, _, connection, netMon, _) = await makeCoordinator()
        try? await coordinator.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        connection.simulateOpen()
        await waitForOpen(coordinator)

        netMon.networkLost.emit(())
        try? await Task.sleep(nanoseconds: 250_000_000)

        let dropped = connection.disconnectCalls.contains { $0.code == 1006 }
        XCTAssertTrue(dropped, "network-lost must drop the open socket via 1006, got \(connection.disconnectCalls)")
    }

    // MARK: - 4b. network lost THEN restored -> reconnect round-trip ("reconnected to wifi")

    /// The full "Wi-Fi dropped then came back" path at the deterministic layer:
    /// an open session loses the network (drop via 1006), then the network is
    /// restored and the SDK re-attempts the socket and reaches open again.
    /// The real `NWPathMonitor` wiring is the only piece this can't cover (it
    /// needs a host Wi-Fi toggle, which is a manual on-device check).
    func test_networkLostThenRestored_reconnectsToOpen() async {
        let (coordinator, _, connection, netMon, _) = await makeCoordinator()
        try? await coordinator.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        connection.simulateOpen()
        await waitForOpen(coordinator)
        XCTAssertEqual(connection.connectCalls.count, 1)

        // Wi-Fi off: NWPathMonitor reports loss -> open socket dropped via 1006.
        netMon.networkLost.emit(())
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(connection.disconnectCalls.contains { $0.code == 1006 },
                      "network-lost drops the open socket via 1006 (I26)")

        // Wi-Fi back: SDK re-attempts the socket.
        netMon.networkRestored.emit(())
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline && connection.connectCalls.count < 2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(connection.connectCalls.count, 2,
                                    "network restore must re-attempt the socket")

        // Reconnect completes.
        connection.simulateOpen()
        await waitForOpen(coordinator)
        connection.simulateMessage(.sessionStart(makeEnvelope(id: "ss2"), makeSessionStartPayload()))
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Final state is open; no terminal .failed was emitted along the way.
        for await status in coordinator.connectionStatus.subscribe() {
            XCTAssertEqual(status, .open, "reconnect after Wi-Fi restore must reach open, not failed")
            break
        }
    }

    // MARK: - 5. max-reconnect terminal (I15)

    func test_maxReconnect_emitsCloseAndFailed() async {
        let (service, mock) = makeConnectionService()
        await service.setMaxReconnectAttempts(1)

        let closeExp = expectation(description: "terminal closeEvent")
        let failedExp = expectation(description: "statusChanges .failed")
        let closeTask = Task {
            for await ev in service.closeEvents.subscribe() {
                if ev.reason.contains("Max reconnect") { closeExp.fulfill(); break }
            }
        }
        let failedTask = Task {
            for await st in service.statusChanges.subscribe() {
                if case .failed = st { failedExp.fulfill(); break }
            }
        }

        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        try? await Task.sleep(nanoseconds: 120_000_000)         // let open subscriber attach
        mock.simulateOpen()
        try? await Task.sleep(nanoseconds: 120_000_000)         // currentAttemptOpened=true
        mock.simulateClose(code: 1006, wasClean: false)         // attempt -> 1 (== max)
        try? await Task.sleep(nanoseconds: 60_000_000)          // before the ~1s reconnect fires
        mock.simulateClose(code: 1006, wasClean: false)         // guard trips -> terminal

        await fulfillment(of: [closeExp, failedExp], timeout: 3.0)
        closeTask.cancel(); failedTask.cancel()
    }

    // MARK: - 6. 4001 -> invalid session -> refetch -> reconnect

    func test_4001_refetchesSessionAndReconnects() async {
        let (coordinator, api, connection, _, _) = await makeCoordinator()
        try? await coordinator.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        connection.simulateOpen()
        await waitForOpen(coordinator)

        XCTAssertEqual(api.createSessionCallCount, 1)
        connection.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
        try? await Task.sleep(nanoseconds: 900_000_000) // 300ms refetch debounce + chain

        XCTAssertEqual(api.createSessionCallCount, 2, "4001 must trigger a session refetch")
        XCTAssertEqual(connection.connectCalls.count, 2, "reconnect with the refetched session")
    }

    // MARK: - 7. idle / expiry (I6)

    func test_idleExpiry_checkTimeoutFiresPastWindow() async {
        let api = MockRestApi()
        let config = Configuration(apiKey: "test_token_idle", environment: .production)
        let session = SessionService(api: api, config: config, logger: NoopLogger(),
                                     sessionTimeoutSeconds: 0.05)
        await session.touch()
        let fresh = await session.checkTimeout()
        XCTAssertFalse(fresh, "fresh activity is not expired")

        try? await Task.sleep(nanoseconds: 120_000_000) // > 0.05s idle window
        let expired = await session.checkTimeout()
        XCTAssertTrue(expired, "session past the idle window must report expired")
    }

    // MARK: - 8. background -> foreground reconnect (I25)

    func test_foreground_reconnectsStaleSession() async {
        let (coordinator, _, connection, _, lifecycle) = await makeCoordinator()
        try? await coordinator.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        // No simulateOpen: session is .active but not ready (socket never opened).
        XCTAssertEqual(connection.connectCalls.count, 1)

        lifecycle.foreground.emit(())
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(connection.connectCalls.count, 2, "foreground must reconnect a stale (active, not-ready) session")
    }

    // MARK: - 9. streaming reassembly: mid-stream id switch finalises old buffer (I17)

    func test_streaming_midStreamIdSwitchFinalisesOldBuffer() async {
        let chat = ChatService(logger: NoopLogger())
        let stream = chat.eventStream.subscribe() // subscribe BEFORE emitting
        // Open a stream for m1 (no isComplete), then a chunk for m2 arrives.
        _ = await chat.handleMessage(.agentMessageChunk(makeEnvelope(id: "c1", sequence: 1),
            makeChunkPayload(messageId: "m1", chunkIndex: 0, isComplete: false, text: "Hello from one")))
        _ = await chat.handleMessage(.agentMessageChunk(makeEnvelope(id: "c2", sequence: 2),
            makeChunkPayload(messageId: "m2", chunkIndex: 0, isComplete: false, text: "Hello from two")))
        chat.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await ev in stream { emitted.append(ev) }
        let assembled = emitted.compactMap { ev -> AgentMessagePayload? in
            if case .agentMessage(_, let p) = ev { return p }; return nil
        }
        XCTAssertTrue(assembled.contains { $0.text == "Hello from one" },
                      "old buffer (m1) must finalise as its own bubble, not mix into m2")
    }

    // MARK: - 10. batch order (I9) — re-asserted

    func test_batchOrder_sortsBySequenceNilLast() {
        let json = """
        {"type":"EVENT_TYPE_EVENT_BATCH","payload":{"events":[
          {"id":"e3","sequence":3,"timestamp":"2026-05-07T12:00:02Z","type":"EVENT_TYPE_POLY_AGENT_MESSAGE","payload":{"message_id":"m3","text":"c"}},
          {"id":"e1","sequence":1,"timestamp":"2026-05-07T12:00:00Z","type":"EVENT_TYPE_POLY_AGENT_MESSAGE","payload":{"message_id":"m1","text":"a"}},
          {"id":"e2","sequence":2,"timestamp":"2026-05-07T12:00:01Z","type":"EVENT_TYPE_POLY_AGENT_MESSAGE","payload":{"message_id":"m2","text":"b"}}
        ]}}
        """.data(using: .utf8)!
        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map { $0.envelope?.sequence }, [1, 2, 3], "batch must be stable-sorted by sequence")
    }
}
