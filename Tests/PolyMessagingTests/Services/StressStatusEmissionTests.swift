// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Robustness / stress probes for connection status emission and envelope
/// dedup. These pin the ordered status sequence emitted across a full
/// open -> drop -> reconnect -> open cycle, and the cross-batch envelope-id
/// collapse performed by `ChatService`.
final class StressStatusEmissionTests: XCTestCase {

    private func makeService() -> (ConnectionService, MockConnection) {
        let mock = MockConnection()
        let url = URL(string: "wss://messaging.poly.ai/ws")!
        let service = ConnectionService(transport: mock, wsBaseURL: url, logger: NoopLogger())
        return (service, mock)
    }

    /// An open -> drop -> reconnect -> open cycle must emit the full ordered
    /// status sequence the reconnect ladder promises:
    ///   .connecting, .open, .reconnecting(1), .connecting, .open
    /// and `connectionStartedAt` must be reset to nil while disconnected
    /// (between the two `.open` states).
    func testConnectionStatusTransitionCompleteness() async {
        let (service, mock) = makeService()

        // Subscribe BEFORE connect so we capture the very first .connecting.
        // statusChanges replays its last value to late subscribers, so a
        // synchronous subscribe here observes the whole ordered stream.
        let collected = StatusCollector()
        let collectorTask = Task {
            for await status in service.statusChanges.subscribe() {
                await collected.append(status)
            }
        }

        // 1) connect -> emits .connecting
        await service.connectToSession(sessionId: "s1", accessToken: "t1")

        // connectToSession spawns observation tasks (startObserving) that
        // subscribe to transport.openEvents/closeEvents. Those subscriptions
        // register asynchronously after connectToSession returns, so give the
        // tasks a beat to begin iterating before simulating transport events —
        // otherwise the openEvents emit (an event-like, non-replayed stream)
        // races ahead of the subscription and handleOpen never fires.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // 2) transport opens -> emits .open, sets connectionStartedAt
        mock.simulateOpen()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let startedAfterOpen = await service.connectionStartedAt
        XCTAssertNotNil(startedAfterOpen, "connectionStartedAt should be set once open")

        // 3) network drop (1006) -> schedules reconnect, emits .reconnecting(1)
        //    and clears connectionStartedAt.
        mock.simulateClose(code: 1006, reason: "drop", wasClean: false)
        try? await Task.sleep(nanoseconds: 150_000_000)

        let startedAfterDrop = await service.connectionStartedAt
        XCTAssertNil(startedAfterDrop, "connectionStartedAt must be nil while disconnected")

        // 4) The scheduled reconnect runs after exponential backoff
        //    (2^0 * jitter ~= 0.8-1.2s for the first attempt). It calls
        //    transport.connect again and emits a second .connecting.
        //    Wait long enough for the backoff timer to fire.
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(mock.connectCalls.count, 2, "reconnect should issue a second connect")

        // 5) transport opens again -> second .open
        mock.simulateOpen()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let startedAfterReopen = await service.connectionStartedAt
        XCTAssertNotNil(startedAfterReopen, "connectionStartedAt should be set again on reopen")

        collectorTask.cancel()

        let statuses = await collected.values

        // Full ordered sequence. The service emits no extra statuses here.
        XCTAssertEqual(statuses, [
            .connecting,
            .open,
            .reconnecting(attempt: 1),
            .connecting,
            .open,
        ], "expected the full ordered open->drop->reconnect->open status sequence")
    }

    /// The same envelope id arriving in two separate batches must be collapsed:
    /// ChatService dedups globally by envelope id (for events with a non-nil
    /// sequence and non-empty id), so the second occurrence is dropped and the
    /// agent message bubble is emitted exactly once.
    func testDuplicateEnvelopeIdInSeparateBatchesCollapsed() async {
        let service = ChatService(logger: NoopLogger())

        let stream = service.eventStream.subscribe()

        let env = makeEnvelope(id: "evt_dup", sequence: 7)
        let payload = makeAgentMessagePayload(messageId: "msg_dup", text: "Hello once")

        // First batch carries the envelope id.
        _ = await service.handleBatch([.agentMessage(env, payload)])
        // Second, SEPARATE batch carries the SAME envelope id (e.g. a server
        // re-delivery after a reconnect cursor replay).
        _ = await service.handleBatch([.agentMessage(env, payload)])

        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let agentMessages = emitted.compactMap { event -> AgentMessagePayload? in
            if case .agentMessage(_, let p) = event { return p }
            return nil
        }

        XCTAssertEqual(
            agentMessages.count, 1,
            "duplicate envelope id across separate batches must be processed once"
        )
        XCTAssertEqual(agentMessages.first?.messageId, "msg_dup")
    }

    /// Captures emitted statuses across actor boundaries.
    private actor StatusCollector {
        private(set) var values: [ConnectionStatus] = []
        func append(_ status: ConnectionStatus) { values.append(status) }
    }
}