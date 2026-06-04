// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Robustness / stress probes for connection status emission and envelope
/// dedup. These pin the ordered status sequence emitted across a full
/// open -> drop -> reconnect -> open cycle, and the cross-batch envelope-id
/// collapse performed by `ChatService`.
///
/// Timing note: the reconnect ladder uses jittered exponential backoff
/// (`pow(2, attempt) * random(0.8...1.2)`), so this suite never sleeps for a
/// fixed "hope it fired" duration. Instead it polls real observable conditions
/// (`connectionStartedAt`, `connectCalls.count`) with a generous deadline, and
/// the ordered-transition assertion is made robust to duplicate/extra emissions
/// while still pinning the exact transition order.
final class StressStatusEmissionTests: XCTestCase {

    private func makeService() -> (ConnectionService, MockConnection) {
        let mock = MockConnection()
        let url = URL(string: "wss://messaging.poly.ai/ws")!
        let service = ConnectionService(transport: mock, wsBaseURL: url, logger: NoopLogger())
        return (service, mock)
    }

    // MARK: - Poll-until-condition helpers

    /// Polls `condition` every ~20ms until it returns true or `timeout`
    /// elapses. Returns whether the condition held. Replaces fixed-duration
    /// `Task.sleep` "settles" so the test tracks the SDK's real state rather
    /// than racing an assumed schedule.
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

    /// Drives the transport to `.open` deterministically.
    ///
    /// `transport.openEvents` is an event-like (non-replayed) stream, and the
    /// service's subscription to it is registered asynchronously by
    /// `startObserving()` AFTER `connectToSession`/`reconnect` returns. A single
    /// `simulateOpen()` therefore races that subscription: if it lands first the
    /// emit is dropped and `handleOpen` never fires. Rather than sleep and hope
    /// the subscriber attached, we re-emit on a poll loop until `handleOpen` has
    /// demonstrably run (it sets `connectionStartedAt`). Re-emits only add
    /// duplicate `.open` statuses, which the sequence assertion collapses.
    private func driveOpen(_ service: ConnectionService, _ mock: MockConnection) async {
        let opened = await waitUntil {
            mock.simulateOpen()
            return await service.connectionStartedAt != nil
        }
        XCTAssertTrue(opened, "transport open should drive handleOpen (connectionStartedAt set)")
    }

    /// An open -> drop -> reconnect -> open cycle must emit the full ordered
    /// status sequence the reconnect ladder promises:
    ///   .connecting, .open, .reconnecting(1), .connecting, .open
    /// and `connectionStartedAt` must be reset to nil while disconnected
    /// (between the two `.open` states).
    func testConnectionStatusTransitionCompleteness() async {
        let (service, mock) = makeService()

        // Subscribe BEFORE connect so we capture the very first .connecting.
        // statusChanges replays its last value to late subscribers, but here we
        // attach synchronously before any emit so we observe the whole ordered
        // stream, not just a replayed snapshot.
        let collected = StatusCollector()
        let collectorTask = Task {
            for await status in service.statusChanges.subscribe() {
                await collected.append(status)
            }
        }

        // 1) connect -> emits .connecting. Wait until the collector has actually
        //    observed it before driving transport events, so the subscription is
        //    proven live (no "let the subscriber attach" sleep).
        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        let sawConnecting = await waitUntil { await collected.contains(.connecting) }
        XCTAssertTrue(sawConnecting, "connect should emit .connecting")

        // 2) transport opens -> emits .open, sets connectionStartedAt. driveOpen
        //    re-emits until handleOpen runs, defeating the openEvents subscribe
        //    race deterministically instead of sleeping.
        await driveOpen(service, mock)
        let startedAfterOpen = await service.connectionStartedAt
        XCTAssertNotNil(startedAfterOpen, "connectionStartedAt should be set once open")

        // 3) network drop (1006) -> schedules reconnect, emits .reconnecting(1)
        //    and clears connectionStartedAt.
        mock.simulateClose(code: 1006, reason: "drop", wasClean: false)
        let clearedAfterDrop = await waitUntil { await service.connectionStartedAt == nil }
        XCTAssertTrue(clearedAfterDrop, "connectionStartedAt must be nil while disconnected")

        // 4) The scheduled reconnect runs after exponential backoff
        //    (2^0 * jitter ≈ 0.8–1.2s for the first attempt). It calls
        //    transport.connect again and emits a second .connecting. Poll for the
        //    second connect rather than guessing the jittered delay.
        let reconnected = await waitUntil { mock.connectCalls.count == 2 }
        XCTAssertTrue(reconnected, "reconnect should issue a second connect")
        // Exactly two connects so far: the original + the single scheduled retry
        // (each reschedule cancels the prior timer, so no connect flood).
        XCTAssertEqual(mock.connectCalls.count, 2, "reconnect should issue exactly one extra connect")

        // 5) transport opens again -> second .open
        await driveOpen(service, mock)
        let startedAfterReopen = await service.connectionStartedAt
        XCTAssertNotNil(startedAfterReopen, "connectionStartedAt should be set again on reopen")

        // Wait until the collector has observed the final .open before snapshotting,
        // so we don't cut the stream off mid-transition.
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

        // The ORDERED TRANSITION INVARIANT: ignoring any duplicate emissions that
        // driveOpen's poll-retry may have produced (collapsing runs of identical
        // statuses), the service walks exactly this open->drop->reconnect->open
        // ladder, in this order, with no extra distinct transition.
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

    /// Captures emitted statuses across actor boundaries. Provides a `collapsed`
    /// view that folds runs of identical consecutive statuses into one, so
    /// idempotent re-emits (from the open-drive poll loop) don't perturb the
    /// asserted transition ladder while every distinct transition is still pinned.
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
