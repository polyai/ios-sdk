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

    // MARK: - Typing-indicator timeout racing message processing

    /// The typing-indicator timer (10s) is armed by `agentThinking` and lives
    /// on a detached `Task` that, when it fires, mutates `isAgentTyping` on the
    /// actor. While that timer is in flight we hammer the actor with many
    /// concurrent `handleMessage` calls (more `agentThinking`, then a
    /// terminating `agentMessage`). Two things must hold:
    ///   1. No crash / no data race — the actor serialises every mutation,
    ///      including the timer's deferred write.
    ///   2. The final state is deterministic: the last event each id processes
    ///      is an `agentMessage`, which calls `stopTypingIndicator()` and
    ///      cancels the timer, so `isAgentTyping` MUST settle to `false`.
    ///
    /// This reproduces the shape of "typing timeout fires while a message is
    /// being processed": the armed timer and the concurrent message stream both
    /// contend for `isAgentTyping`, and the actor must leave a consistent state.
    func testTypingIndicatorTimeoutFiresWhileMessageProcessing() async {
        let service = makeChatService()

        // Arm the typing timer once up front (10s window — stays pending for
        // the whole test) so a deferred timer write is genuinely in flight
        // while the concurrent storm runs.
        _ = await service.handleMessage(.agentThinking(makeEnvelope(id: "warmup_think")))
        let typingAfterArm = await service.isAgentTyping
        XCTAssertTrue(typingAfterArm, "agentThinking should set isAgentTyping")

        // Concurrent storm: many tasks each re-arm typing then immediately
        // terminate it with an agentMessage. Distinct envelope ids so global
        // dedup never swallows them (agentThinking is transient/nil-sequence
        // and always passes; agentMessage carries a sequence so needs unique
        // ids).
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    _ = await service.handleMessage(
                        .agentThinking(makeEnvelope(id: "think_\(i)", sequence: nil))
                    )
                    _ = await service.handleMessage(
                        .agentMessage(
                            makeEnvelope(id: "msg_\(i)"),
                            makeAgentMessagePayload(messageId: "m_\(i)", text: "reply \(i)")
                        )
                    )
                }
            }
        }

        // After the storm settles, drive one final terminating message so the
        // last actor-serialised operation is unambiguously a typing-stop.
        _ = await service.handleMessage(
            .agentMessage(makeEnvelope(id: "msg_final"), makeAgentMessagePayload(text: "final"))
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
    /// `connectionService.currentStatus() == .open`. We force the heartbeat
    /// service to tick fast (1s) while the transport is NOT open (it sits in
    /// `.connecting` after `start()` because we never call `simulateOpen`), and
    /// assert zero heartbeat frames are sent. Then we open the socket and
    /// assert heartbeats DO start flowing — proving the gate suppresses sends
    /// only while not open, not always.
    func testHeartbeatSuppressedWhenNotOpen() async throws {
        let (coordinator, _, connection, heartbeat) = await makeCoordinator(heartbeatInterval: 1)
        try await coordinator.start()

        // Let observation tasks (incl. observeHeartbeatTick) attach.
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Transport is `.connecting` (start → connect, no open simulated).
        let statusBeforeOpen = await connection.status
        if case .open = statusBeforeOpen {
            XCTFail("Precondition: transport must NOT be open yet")
        }

        // Force the heartbeat to tick repeatedly while NOT open. The
        // Coordinator's tick subscriber will run handleHeartbeatTick, whose
        // open-gate should suppress every send.
        await heartbeat.start(intervalSeconds: 1)

        // Wait across multiple tick windows.
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        let suppressedCount = heartbeatCount(connection)
        XCTAssertEqual(
            suppressedCount, 0,
            "No heartbeat frames may be sent while the connection is not open"
        )

        // Now open the socket. handleConnectionOpen restarts the heartbeat,
        // and ticks should now produce real heartbeat sends.
        connection.simulateOpen()
        let statusAfterOpen = await connection.status
        guard case .open = statusAfterOpen else {
            return XCTFail("Transport should be .open after simulateOpen")
        }

        // Give a couple of tick windows for heartbeats to flow now that the
        // gate is satisfied.
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        let openCount = heartbeatCount(connection)
        XCTAssertGreaterThanOrEqual(
            openCount, 1,
            "Heartbeats must flow once the connection is open (gate is open-only, not always-off)"
        )

        await coordinator.destroy()
    }
}
