// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress probes for lifecycle races around the typing-indicator timer and the
/// heartbeat tick gate. Assert CURRENT intended behaviour; must pass unchanged.
final class StressLifecycleRaceTests: XCTestCase {

    private func makeChatService() -> ChatService {
        ChatService(logger: NoopLogger())
    }

    // MARK: - Collector actors (no data races on shared mutable state)

    /// Actor-isolated so the test thread can read the count while a drain Task appends.
    private actor AgentMessageCounter {
        private(set) var count = 0
        func record() { count += 1 }
        func snapshot() -> Int { count }
    }

    /// Positive control: proves the heartbeat timer actually fired, so a
    /// "0 frames sent" assertion is meaningful (timer ticked but gate suppressed).
    private actor TickCounter {
        private(set) var count = 0
        func record() { count += 1 }
        func snapshot() -> Int { count }
    }

    // MARK: - Typing-indicator timeout racing message processing

    /// Arms the typing timer, then storms the actor with concurrent handleMessage
    /// calls. Invariants: no data race (actor serialises every mutation incl. the
    /// timer's deferred write); the final agentMessage settles isAgentTyping to
    /// false; and every distinct message survives dedup.
    ///
    /// Dedup contract: ChatService de-duplicates by envelope id (only when the
    /// envelope has a non-nil sequence and non-empty id). Each agentMessage uses a
    /// distinct id AND distinct non-nil sequence so neither dedup path can swallow
    /// it — verified by counting emitted .agentMessage events (200 + 1 final).
    func testTypingIndicatorTimeoutFiresWhileMessageProcessing() async {
        let service = makeChatService()

        // Subscribe BEFORE emitting: the Multicaster does not replay, so a late
        // subscriber would miss emits.
        let counter = AgentMessageCounter()
        let stream = service.eventStream.subscribe()
        let drain = Task {
            for await event in stream {
                if case .agentMessage = event { await counter.record() }
            }
        }

        // Arm the typing timer (10s window stays pending) so a deferred timer
        // write is genuinely in flight during the storm.
        _ = await service.handleMessage(.agentThinking(makeEnvelope(id: "warmup_think", sequence: nil)))
        let typingAfterArm = await service.isAgentTyping
        XCTAssertTrue(typingAfterArm, "agentThinking should set isAgentTyping")

        // Concurrent storm: each task re-arms typing then terminates it with a
        // uniquely-keyed agentMessage (distinct id + sequence, dedup-resistant).
        let stormCount = 200
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<stormCount {
                group.addTask {
                    _ = await service.handleMessage(
                        .agentThinking(makeEnvelope(id: "think_\(i)", sequence: nil))
                    )
                    _ = await service.handleMessage(
                        .agentMessage(
                            makeEnvelope(id: "msg_\(i)", sequence: i + 1),
                            makeAgentMessagePayload(messageId: "m_\(i)", text: "reply \(i)")
                        )
                    )
                }
            }
        }

        // Final terminating message so the last serialised op is unambiguously a
        // typing-stop; sequence past the storm range stays unique.
        _ = await service.handleMessage(
            .agentMessage(
                makeEnvelope(id: "msg_final", sequence: stormCount + 1),
                makeAgentMessagePayload(messageId: "m_final", text: "final")
            )
        )

        let finalTyping = await service.isAgentTyping
        XCTAssertFalse(
            finalTyping,
            "After an agentMessage stops typing, isAgentTyping must settle to false"
        )

        // Sanity: re-arming after the storm still works (timer/state not wedged).
        _ = await service.handleMessage(.agentThinking(makeEnvelope(id: "think_again", sequence: nil)))
        let reArmed = await service.isAgentTyping
        XCTAssertTrue(reArmed, "Typing indicator must be re-armable after the race storm")

        // Finish the stream so the drain Task terminates, then assert every
        // distinct agentMessage reached consumers.
        service.eventStream.finish()
        let expectedMessages = stormCount + 1  // storm + final
        let allDelivered = await waitUntil(timeout: 5) {
            await counter.snapshot() == expectedMessages
        }
        let delivered = await counter.snapshot()
        XCTAssertTrue(
            allDelivered,
            "Every distinct agentMessage must survive dedup and reach consumers; "
            + "saw \(delivered) of \(expectedMessages)"
        )
        XCTAssertEqual(
            delivered, expectedMessages,
            "Exactly the distinct agent messages should be emitted (no swallows, no dupes)"
        )

        drain.cancel()
        await service.destroy()
    }

    // MARK: - Heartbeat suppressed while connection is not open

    private func makeCoordinator(
        heartbeatInterval: Int
    ) async -> (Coordinator, MockRestApi, MockConnection, HeartbeatService) {
        // Clear persisted session so resume() doesn't short-circuit createSession.
        SessionStore(apiKey: "test_token").clear()

        let api = MockRestApi()
        let connection = MockConnection()
        let config = Configuration(apiKey: "test_token", environment: .us)
        let logger = NoopLogger()

        let session = SessionService(api: api, config: config, logger: logger)
        let wsURL = URL(string: "wss://messaging.poly.ai/ws")!
        let connService = ConnectionService(transport: connection, wsBaseURL: wsURL, logger: logger)
        let chat = ChatService(logger: logger)
        let heartbeat = HeartbeatService(intervalSeconds: heartbeatInterval)

        let coordinator = Coordinator(
            sessionService: session,
            connectionService: connService,
            chatService: chat,
            heartbeatService: heartbeat,
            logger: logger
        )

        return (coordinator, api, connection, heartbeat)
    }

    private func heartbeatCount(_ connection: MockConnection) -> Int {
        connection.sentEvents.filter {
            if case .heartbeat = $0 { return true }
            return false
        }.count
    }

    /// `Coordinator.handleHeartbeatTick` gates the `.heartbeat` send on
    /// `currentStatus() == .open`. A positive-control tick subscriber proves the
    /// timer actually fired during the not-open window (else "0 sent" is vacuous);
    /// only then do we assert the gate suppressed every send. Opening the socket
    /// must then let heartbeats flow — proving the gate is open-only, not always-off.
    /// All `sentEvents` reads happen after stop() (writer quiesced) to avoid a race.
    func testHeartbeatSuppressedWhenNotOpen() async throws {
        let (coordinator, _, connection, heartbeat) = await makeCoordinator(heartbeatInterval: 1)

        // Attach the tick observer BEFORE start(): tick does not replay, so a
        // late subscriber would miss ticks.
        let ticks = TickCounter()
        let tickStream = heartbeat.tick.subscribe()
        let tickDrain = Task {
            for await _ in tickStream { await ticks.record() }
        }

        try await coordinator.start()

        // Wait until the transport has left .idle (start → connect → .connecting).
        let leftIdle = await waitUntil(timeout: 5) {
            if case .idle = await connection.status { return false }
            return true
        }
        XCTAssertTrue(leftIdle, "Transport should leave .idle after start()")

        // Precondition: transport is NOT open (start → connect, no open simulated).
        let statusBeforeOpen = await connection.status
        if case .open = statusBeforeOpen {
            XCTFail("Precondition: transport must NOT be open yet")
        }

        // Drive the heartbeat to tick repeatedly while NOT open; the open-gate
        // in handleHeartbeatTick should suppress every send.
        await heartbeat.start(intervalSeconds: 1)

        // Positive control: require >=2 ticks while not-open, else the "0 sent"
        // assertion below is vacuous.
        let timerTicked = await waitUntil(timeout: 5) {
            await ticks.snapshot() >= 2
        }
        let ticksWhileClosed = await ticks.snapshot()
        XCTAssertTrue(
            timerTicked,
            "Positive control: the heartbeat timer must tick while not-open so "
            + "the suppression assertion is meaningful (saw \(ticksWhileClosed) ticks)"
        )

        // Quiesce the writer before reading the mock, then assert the gate
        // suppressed every send despite the timer firing.
        await heartbeat.stop()
        let suppressedCount = heartbeatCount(connection)
        XCTAssertEqual(
            suppressedCount, 0,
            "No heartbeat frames may be sent while the connection is not open "
            + "(timer fired \(ticksWhileClosed)x but the open-gate suppressed all sends)"
        )

        // Open the socket: handleConnectionOpen restarts the heartbeat and ticks
        // should now produce real sends.
        connection.simulateOpen()
        let openedUp = await waitUntil(timeout: 5) {
            if case .open = await connection.status { return true }
            return false
        }
        XCTAssertTrue(openedUp, "Transport should be .open after simulateOpen")

        // Watch the actor-isolated tick counter (race-free) rather than polling
        // the mock while the writer is live.
        let ticksAtOpen = await ticks.snapshot()
        let ticked = await waitUntil(timeout: 5) {
            await ticks.snapshot() >= ticksAtOpen + 2
        }
        XCTAssertTrue(ticked, "Heartbeat timer must keep ticking after open")

        // After stop() an in-flight handleHeartbeatTick may still be appending,
        // so wait for the count to stabilise (two equal reads) before asserting.
        await heartbeat.stop()
        var lastSeen = -1
        _ = await waitUntil(timeout: 5) {
            let now = heartbeatCount(connection)
            defer { lastSeen = now }
            return now == lastSeen
        }
        let totalTicks = await ticks.snapshot()
        let openCount = heartbeatCount(connection)
        XCTAssertGreaterThanOrEqual(
            openCount, 1,
            "Heartbeats must flow once the connection is open (gate is open-only, not always-off)"
        )
        XCTAssertLessThanOrEqual(
            openCount, totalTicks,
            "Each heartbeat send is driven by one tick — sends cannot exceed observed ticks"
        )

        tickDrain.cancel()
        await coordinator.destroy()
    }
}
