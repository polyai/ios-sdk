// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress / race probes for the voice-call lifecycle (the voice twin of the
/// chat `StressLifecycleRace` / `StressReconnectStorm` suites). Invariants:
///  1. `start()` is idempotent and `end()` mid-`start()` aborts the pipeline
///     cleanly (no offer into a dead call, resources released).
///  2. Repeated signaling drop→reconnect cycles never fail a healthy call, and
///     ICE generated inside every gap is delivered after each reconnect.
///  3. Inbound remote-ICE bursts that beat the answer are buffered and flushed
///     in arrival order.
///  4. Terminal states are sticky: `end()` after a failure must not repaint
///     `.failed` as `.ended`, and repeated `end()` tears down exactly once.
final class StressCallLifecycleTests: XCTestCase {

    private func makeCoordinator(
        api: MockRestApi = MockRestApi(),
        conn: MockConnection = MockConnection(),
        channel: MockSignalingChannel = MockSignalingChannel(),
        media: StubMediaEngine = StubMediaEngine()
    ) -> CallCoordinator {
        let logger = NoopLogger()
        let linker = VoiceSessionLinker(
            connection: conn,
            wsBaseURL: URL(string: "wss://messaging.test/ws")!,
            logger: logger
        )
        return CallCoordinator(
            api: api,
            linker: linker,
            channel: channel,
            media: media,
            authToken: "tok",
            streamingEnabled: true,
            logger: logger,
            disconnectGraceNanos: 300_000_000,
            reconnectBaseNanos: 20_000_000,          // fast backoff for tests
            reconnectConnectTimeoutNanos: 400_000_000
        )
    }

    private func arm(_ coord: CallCoordinator, conn: MockConnection) async throws {
        let startTask = Task { try await coord.start() }
        let connected = await waitUntil { conn.connectCalls.count == 1 }
        XCTAssertTrue(connected, "linker opens the messaging WS")
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await startTask.value
    }

    /// Drive an armed coordinator to `.connected` with a known session id.
    private func connect(_ coord: CallCoordinator, channel: MockSignalingChannel, media: StubMediaEngine) async {
        channel.emit(.opened)
        _ = await waitUntil { channel.sentFrames(ofType: "offer").count == 1 }
        channel.emit(.message(frame([
            "type": "answer", "sessionId": "sig_1",
            "data": ["type": "answer", "sdp": "v=0"],
        ])))
        _ = await waitUntil { media.acceptedAnswer == "v=0" }
        media.driveState(.connected)
        let connected = await waitUntil { await coord.state == .connected }
        XCTAssertTrue(connected)
    }

    private func frame(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func iceFrame(_ candidate: String) -> Data {
        frame(["type": "ice-candidate", "data": ["candidate": candidate, "sdpMid": "0", "sdpMLineIndex": 0]])
    }

    // MARK: - start()/end() races

    func test_doubleStart_armsPipelineOnce() async throws {
        let api = MockRestApi()
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(api: api, conn: conn, media: media)
        try await arm(coord, conn: conn)

        // A second start() on the live call must be a no-op, not a re-auth.
        try await coord.start()
        XCTAssertEqual(api.obtainTokenCallCount, 1)
        XCTAssertEqual(api.createSessionCallCount, 1)
        XCTAssertEqual(media.createOfferCount, 1)
        XCTAssertEqual(conn.connectCalls.count, 1)
    }

    func test_endMidStart_abortsPipeline() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)

        // start() is suspended inside the linker (awaiting SESSION_START)…
        let startTask = Task { try await coord.start() }
        _ = await waitUntil { conn.connectCalls.count == 1 }

        // …when the user hangs up.
        await coord.end()
        let ended = await waitUntil { await coord.state == .ended }
        XCTAssertTrue(ended)

        // The linker then resolves — the pipeline must notice it's dead and abort.
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        do {
            try await startTask.value
            XCTFail("start() must throw when the call was ended mid-pipeline")
        } catch {
            XCTAssertEqual(error as? PolyError, .voice(.signalingFailed("Call ended before it connected")))
        }

        // No offer went out into the dead call, resources were released, and
        // the abort didn't repaint the user's .ended as .failed.
        XCTAssertTrue(channel.sentFrames(ofType: "offer").isEmpty)
        let released = await waitUntil { media.closeCount >= 1 && channel.closeCalled }
        XCTAssertTrue(released, "media + channel released after an aborted start")
        let state = await coord.state
        XCTAssertEqual(state, .ended)
    }

    // MARK: - Reconnect storm

    func test_reconnectStorm_survivesAndDeliversEveryGapCandidate() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        await connect(coord, channel: channel, media: media)

        for cycle in 1...4 {
            let opensBefore = channel.openCount
            channel.emit(.closed(code: 1006, reason: "storm \(cycle)"))
            let reopening = await waitUntil { channel.openCount > opensBefore }
            XCTAssertTrue(reopening, "cycle \(cycle): the drop triggers a reconnect")

            // A candidate generated inside the gap must be buffered, then
            // delivered once the reconnect lands.
            media.emitLocalCandidate(ICECandidate(candidate: "cand:gap-\(cycle)", sdpMid: "0", sdpMLineIndex: 0))
            channel.emit(.opened)
            let delivered = await waitUntil {
                channel.sentFrames(ofType: "ice-candidate")
                    .contains { ($0["data"] as? [String: Any])?["candidate"] as? String == "cand:gap-\(cycle)" }
            }
            XCTAssertTrue(delivered, "cycle \(cycle): the gap candidate is flushed after reconnect")

            // The reconnect loop polls signalingConnected every 100ms before it
            // clears its in-flight flag; a drop emitted inside that window is
            // (correctly) treated as part of the same reconnect and ignored.
            // Settle past it so every cycle exercises a fresh drop.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // Four straight storms never failed the call.
        let state = await coord.state
        XCTAssertEqual(state, .connected, "the call survives repeated drop→reconnect cycles")
    }

    // MARK: - Inbound ICE burst

    func test_remoteIceBurstBeforeAnswer_flushedCompletelyInOrder() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        channel.emit(.opened)

        let count = 50
        for i in 0..<count {
            channel.emit(.message(iceFrame("cand:burst-\(i)")))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(media.remoteCandidates.isEmpty, "pre-answer remote ICE stays buffered")

        channel.emit(.message(frame([
            "type": "answer", "sessionId": "sig_1",
            "data": ["type": "answer", "sdp": "v=0"],
        ])))
        let flushed = await waitUntil { media.remoteCandidates.count == count }
        XCTAssertTrue(flushed, "every buffered candidate reaches the peer, none dropped")
        XCTAssertEqual(
            media.remoteCandidates.map(\.candidate),
            (0..<count).map { "cand:burst-\($0)" },
            "buffered remote ICE flushes in arrival order"
        )
    }

    // MARK: - Mute storm

    func test_concurrentMuteToggles_settleOnLastUserIntent() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn)

        // A burst of racing toggles must not crash or wedge the actor…
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { await coord.setMuted(i % 2 == 0) }
            }
        }
        // …and once the dust settles the latest intent wins deterministically.
        await coord.setMuted(true)
        XCTAssertEqual(media.muted, true)
        let muted = await coord.isMuted
        XCTAssertTrue(muted)
    }

    // MARK: - Terminal-state stickiness

    func test_endAfterFailure_keepsFailedState() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let coord = makeCoordinator(conn: conn, channel: channel)
        try await arm(coord, conn: conn)
        channel.emit(.opened)
        channel.emit(.message(frame(["type": "error", "data": ["message": "boom"]])))
        let failed = await waitUntil {
            if case .failed = await coord.state { return true }
            return false
        }
        XCTAssertTrue(failed)

        // A late end() (e.g. the user taps hang-up on the error screen) must
        // not repaint the failure as a clean .ended.
        await coord.end()
        let state = await coord.state
        XCTAssertEqual(state, .failed(.voice(.signalingFailed("boom"))))
    }

    func test_repeatedEnd_tearsDownOnce() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        await connect(coord, channel: channel, media: media)

        await coord.end()
        await coord.end()
        await coord.end()

        let tornDown = await waitUntil { media.closeCount >= 1 && channel.closeCalled }
        XCTAssertTrue(tornDown)
        try? await Task.sleep(nanoseconds: 100_000_000) // let any stray teardown tasks run
        XCTAssertEqual(media.closeCount, 1, "repeated end() releases the engine exactly once")
        XCTAssertEqual(channel.sentFrames(ofType: "close").count, 1,
                       "exactly one graceful close frame goes to the gateway")
        let state = await coord.state
        XCTAssertEqual(state, .ended)
    }
}
