// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress probes for connection status emission and cross-batch envelope-id
/// dedup. Because the reconnect ladder uses jittered exponential backoff, this
/// suite polls observable conditions (`connectionStartedAt`, `connectCalls`)
/// rather than sleeping a fixed duration.
final class StressStatusEmissionTests: XCTestCase {

    private func makeService() -> (ConnectionService, MockConnection) {
        let mock = MockConnection()
        let url = URL(string: "wss://messaging.poly.ai/ws")!
        let service = ConnectionService(transport: mock, wsBaseURL: url, logger: NoopLogger())
        return (service, mock)
    }

    // MARK: - Poll-until-condition helpers

    /// Polls `condition` until it returns true or `timeout` elapses.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollMs: UInt64 = 20,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
        return await condition()
    }

    /// `openEvents` is a non-replayed stream whose subscription is registered
    /// asynchronously after `connectToSession`/`reconnect` returns, so a single
    /// `simulateOpen()` can race the subscriber and be dropped. Re-emit until
    /// `handleOpen` has run (sets `connectionStartedAt`); duplicate `.open`
    /// statuses are collapsed by the sequence assertion.
    private func driveOpen(_ service: ConnectionService, _ mock: MockConnection) async {
        let opened = await waitUntil {
            mock.simulateOpen()
            return await service.connectionStartedAt != nil
        }
        XCTAssertTrue(opened, "transport open should drive handleOpen (connectionStartedAt set)")
    }

    /// An open -> drop -> reconnect -> open cycle must emit the full ordered
    /// sequence .connecting, .open, .reconnecting(1), .connecting, .open, with
    /// `connectionStartedAt` reset to nil while disconnected.
    func testConnectionStatusTransitionCompleteness() async {
        let (service, mock) = makeService()

        // Subscribe before connect so we capture the very first .connecting.
        let collected = StatusCollector()
        let collectorTask = Task {
            for await status in service.statusChanges.subscribe() {
                await collected.append(status)
            }
        }

        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        let sawConnecting = await waitUntil { await collected.contains(.connecting) }
        XCTAssertTrue(sawConnecting, "connect should emit .connecting")

        await driveOpen(service, mock)
        let startedAfterOpen = await service.connectionStartedAt
        XCTAssertNotNil(startedAfterOpen, "connectionStartedAt should be set once open")

        // Network drop: schedules reconnect, emits .reconnecting(1), clears connectionStartedAt.
        mock.simulateClose(code: 1006, reason: "drop", wasClean: false)
        let clearedAfterDrop = await waitUntil { await service.connectionStartedAt == nil }
        XCTAssertTrue(clearedAfterDrop, "connectionStartedAt must be nil while disconnected")

        let reconnected = await waitUntil { mock.connectCalls.count == 2 }
        XCTAssertTrue(reconnected, "reconnect should issue a second connect")
        // Exactly one extra connect: each reschedule cancels the prior timer, so no flood.
        XCTAssertEqual(mock.connectCalls.count, 2, "reconnect should issue exactly one extra connect")

        await driveOpen(service, mock)
        let startedAfterReopen = await service.connectionStartedAt
        XCTAssertNotNil(startedAfterReopen, "connectionStartedAt should be set again on reopen")

        let expected: [ConnectionStatus] = [
            .connecting,
            .open,
            .reconnecting(attempt: 1),
            .connecting,
            .open,
        ]
        let sawFinalSequence = await waitUntil { await collected.collapsed() == expected }
        collectorTask.cancel()

        let collapsed = await collected.collapsed()

        // Ordered-transition invariant: collapsing duplicate emissions, the service
        // walks exactly this ladder in order with no extra distinct transition.
        XCTAssertTrue(sawFinalSequence,
                      "expected the full ordered open->drop->reconnect->open status sequence; got \(collapsed)")
        XCTAssertEqual(collapsed, expected,
                       "collapsed status ladder must match the promised transition order; got \(collapsed)")

        // No terminal breaker on a single clean reconnect cycle.
        let raw = await collected.values
        let failed = raw.contains { if case .failed = $0 { return true }; return false }
        XCTAssertFalse(failed, "a single open->drop->reconnect->open cycle must not emit .failed")

        await service.destroy()
    }

    /// ChatService dedups globally by envelope id (non-nil sequence, non-empty
    /// id), so the same envelope id across two separate batches emits the agent
    /// message exactly once.
    func testDuplicateEnvelopeIdInSeparateBatchesCollapsed() async {
        let service = ChatService(logger: NoopLogger())

        let stream = service.eventStream.subscribe()

        let env = makeEnvelope(id: "evt_dup", sequence: 7)
        let payload = makeAgentMessagePayload(messageId: "msg_dup", text: "Hello once")

        _ = await service.handleBatch([.agentMessage(env, payload)])
        // Separate batch re-delivers the same envelope id (e.g. reconnect cursor replay).
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

    /// Captures emitted statuses; `collapsed()` folds runs of identical
    /// consecutive statuses so idempotent re-emits don't perturb the ladder.
    private actor StatusCollector {
        private(set) var values: [ConnectionStatus] = []
        func append(_ status: ConnectionStatus) { values.append(status) }
        func contains(_ status: ConnectionStatus) -> Bool { values.contains(status) }

        func collapsed() -> [ConnectionStatus] {
            var out: [ConnectionStatus] = []
            for s in values where out.last != s {
                out.append(s)
            }
            return out
        }
    }
}
