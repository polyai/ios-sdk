// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress / robustness probes for lifecycle races around the typing-indicator
/// timer (ChatService) and the heartbeat tick gate (Coordinator +
/// HeartbeatService). These assert the CURRENT, intended behaviour under
/// concurrent pressure — they must pass without any source change.
final class StressLifecycleRaceTests: XCTestCase {

    private func makeChatService() -> ChatService {
        ChatService(logger: NoopLogger())
    }

    // MARK: - Collector actors (no data races on shared mutable state)

    /// Counts `.agentMessage` events seen on a ChatService event stream from a
    /// background drain Task. Actor-isolated so the test thread can read the
    /// count safely while the drain Task keeps appending.
    private actor AgentMessageCounter {
        private(set) var count = 0
        func record() { count += 1 }
        func snapshot() -> Int { count }
    }

    /// Counts heartbeat ticks observed on `HeartbeatService.tick` from a
    /// background drain Task. Used as a *positive control*: it proves the
    /// heartbeat timer actually fired during a window, so a "0 frames sent"
    /// assertion is meaningful (the timer ticked but the gate suppressed).
    private actor TickCounter {
        private(set) var count = 0
        func record() { count += 1 }
        func snapshot() -> Int { count }
    }

    // MARK: - Typing-indicator timeout racing message processing

    /// The typing-indicator timer (10s) is armed by `agentThinking` and lives
    /// on a detached `Task` that, when it fires, mutates `isAgentTyping` on the
    /// actor. While that timer is in flight we hammer the actor with many
    /// concurrent `handleMessage` calls (more `agentThinking`, then a
    /// terminating `agentMessage`). Three things must hold:
    ///   1. No crash / no data race — the actor serialises every mutation,
    ///      including the timer's deferred write.
    ///   2. The final state is deterministic: the last event each id processes
    ///      is an `agentMessage`, which calls `stopTypingIndicator()` and
    ///      cancels the timer, so `isAgentTyping` MUST settle to `false`.
    ///   3. Every distinct agent message survives the global dedup and reaches
    ///      consumers (see the dedup note below).
    ///
    /// Dedup note: ChatService de-duplicates by **envelope id** (only when the
    /// envelope carries a non-nil sequence and a non-empty id). To make the
    /// dedup-resistance real (not accidental), each `agentMessage` here uses a
    /// *distinct id AND a distinct non-nil sequence* — so even with sequence
    /// dedup in play every message is unique and none may be swallowed. We
    /// assert that by counting the `.agentMessage` events emitted on the
    /// ChatService stream: 200 storm messages + 1 final = 201, exactly.
    ///
    /// This reproduces the shape of "typing timeout fires while a message is
    /// being processed": the armed timer and the concurrent message stream both
    /// contend for `isAgentTyping`, and the actor must leave a consistent state.
    func testTypingIndicatorTimeoutFiresWhileMessageProcessing() async {
        let service = makeChatService()

        // Attach the event-stream collector BEFORE emitting anything. The
        // stream's Multicaster does not replay, so a late subscriber would
        // miss emits — we never rely on a sleep to "let the subscriber attach".
        let counter = AgentMessageCounter()
        let stream = service.eventStream.subscribe()
        let drain = Task {
            for await event in stream {
                if case .agentMessage = event { await counter.record() }
            }
        }

        // Arm the typing timer once up front (10s window — stays pending for
        // the whole test) so a deferred timer write is genuinely in flight
        // while the concurrent storm runs.
        _ = await service.handleMessage(.agentThinking(makeEnvelope(id: "warmup_think", sequence: nil)))
        let typingAfterArm = await service.isAgentTyping
        XCTAssertTrue(typingAfterArm, "agentThinking should set isAgentTyping")

        // Concurrent storm: many tasks each re-arm typing then immediately
        // terminate it with an agentMessage. Each agentMessage carries a
        // distinct id AND a distinct non-nil sequence, so neither id-dedup nor
        // sequence-dedup can swallow it.
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

        // After the storm settles, drive one final terminating message so the
        // last actor-serialised operation is unambiguously a typing-stop. Its
        // sequence is past the storm range so it stays unique.
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

        // Dedup-resistance, verified: drain the stream and assert every
        // distinct agent message reached consumers. Finish the stream so the
        // drain Task terminates deterministically, then poll the actor count.
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
        // Clear any persisted session so resume() doesn't short-circuit
        // createSession (mirrors CoordinatorTests).
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

    /// `Coordinator.handleHeartbeatTick` gates the actual `.heartbeat` send on
    /// `connectionService.currentStatus() == .open`. We drive the heartbeat
    /// service to tick fast (1s) while the transport is NOT open (it sits in
    /// `.connecting` after `start()` because we never call `simulateOpen`).
    ///
    /// The hard part of this probe is making "0 frames sent" *meaningful*: a
    /// timer that never ticked would also send 0. So we attach a positive
    /// control — an independent subscriber to `HeartbeatService.tick` — and
    /// require it to observe real ticks during the not-open window. Only once
    /// the timer has demonstrably fired do we assert that the gate suppressed
    /// every send (== 0). Then we open the socket and require heartbeats to
    /// actually flow, proving the gate is open-only, not always-off.
    ///
    /// All reads of `connection.sentEvents` happen only after the heartbeat is
    /// stopped (writer quiesced), so there is no concurrent-mutation race on
    /// the mock's event array. The two tick counters are actor-isolated.
    func testHeartbeatSuppressedWhenNotOpen() async throws {
        let (coordinator, _, connection, heartbeat) = await makeCoordinator(heartbeatInterval: 1)

        // Attach the positive-control tick observer BEFORE the timer starts.
        // `HeartbeatService.tick` does not replay, so attaching after start()
        // could miss ticks; attach first so every tick is counted.
        let ticks = TickCounter()
        let tickStream = heartbeat.tick.subscribe()
        let tickDrain = Task {
            for await _ in tickStream { await ticks.record() }
        }

        try await coordinator.start()

        // Poll until the Coordinator's observation tasks have attached and the
        // transport has left .idle (start → connect → .connecting). No sleep:
        // we wait on the real condition.
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

        // Drive the heartbeat to tick repeatedly while NOT open. The
        // Coordinator's tick subscriber runs handleHeartbeatTick, whose
        // open-gate should suppress every send.
        await heartbeat.start(intervalSeconds: 1)

        // POSITIVE CONTROL: wait until the timer has demonstrably ticked at
        // least twice during the not-open window. If this never becomes true
        // the timer didn't fire and the "0 sent" assertion below would be
        // vacuous — so we fail loudly here instead.
        let timerTicked = await waitUntil(timeout: 5) {
            await ticks.snapshot() >= 2
        }
        let ticksWhileClosed = await ticks.snapshot()
        XCTAssertTrue(
            timerTicked,
            "Positive control: the heartbeat timer must tick while not-open so "
            + "the suppression assertion is meaningful (saw \(ticksWhileClosed) ticks)"
        )

        // Quiesce the writer before reading the mock's event array, then assert
        // the gate suppressed every send despite the timer having fired.
        await heartbeat.stop()
        let suppressedCount = heartbeatCount(connection)
        XCTAssertEqual(
            suppressedCount, 0,
            "No heartbeat frames may be sent while the connection is not open "
            + "(timer fired \(ticksWhileClosed)x but the open-gate suppressed all sends)"
        )

        // Now open the socket. handleConnectionOpen restarts the heartbeat,
        // and ticks should now produce real heartbeat sends.
        connection.simulateOpen()
        let openedUp = await waitUntil(timeout: 5) {
            if case .open = await connection.status { return true }
            return false
        }
        XCTAssertTrue(openedUp, "Transport should be .open after simulateOpen")

        // Wait until heartbeats actually flow now that the gate is satisfied.
        // We watch the actor-isolated tick counter (race-free) rather than
        // polling the mock's event array while the writer is live.
        let ticksAtOpen = await ticks.snapshot()
        let ticked = await waitUntil(timeout: 5) {
            await ticks.snapshot() >= ticksAtOpen + 2
        }
        XCTAssertTrue(ticked, "Heartbeat timer must keep ticking after open")

        // Quiesce the writer, then read the final count. After stop() a tick
        // emitted just beforehand may still have a handleHeartbeatTick in
        // flight appending to the mock, so wait for the count to STABILISE
        // (two equal consecutive reads) before asserting — no race on the read.
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
