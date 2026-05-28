// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Deterministic, network-free tests of the full voice-call pipeline. Drives a
/// real `CallCoordinator` over a `MockConnection` (messaging-link WS), a
/// `MockSignalingChannel` (gateway), and a `StubMediaEngine` — the same code
/// path the live gateway round-trip exercises, minus the sockets.
final class CallCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        api: MockRestApi = MockRestApi(),
        conn: MockConnection = MockConnection(),
        channel: MockSignalingChannel = MockSignalingChannel(),
        media: StubMediaEngine = StubMediaEngine()
    ) -> CallCoordinator {
        let logger = OSLogLogger(level: .none)
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
            logger: logger
        )
    }

    /// Drives `start()` to completion: feeds SESSION_START so the linker
    /// resolves and `start()` returns. Returns once the pipeline is armed.
    private func arm(_ coord: CallCoordinator, conn: MockConnection) async throws {
        let startTask = Task { try await coord.start() }
        let connected = await waitUntil { conn.connectCalls.count == 1 }
        XCTAssertTrue(connected, "linker opens the messaging WS")
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await startTask.value
    }

    private func callState(_ coord: CallCoordinator) async -> CallState {
        await coord.state
    }

    // MARK: - Happy path

    func test_pipeline_offer_answer_ice_connect_end() async throws {
        let api = MockRestApi()
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(api: api, conn: conn, channel: channel, media: media)

        try await arm(coord, conn: conn)

        XCTAssertEqual(api.obtainTokenCallCount, 1)
        XCTAssertEqual(api.createSessionCallCount, 1)
        XCTAssertEqual(media.createOfferCount, 1)

        // The messaging session is linked to the WebRTC call.
        let linkFrames = conn.sentRawData
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .filter { ($0["type"] as? String) == "EVENT_TYPE_LINK_TO_WEBRTC_CONVERSATION" }
        XCTAssertEqual(linkFrames.count, 1)
        XCTAssertNotNil((linkFrames.first?["payload"] as? [String: Any])?["call_sid"] as? String)

        // A local ICE candidate generated before the answer must be buffered.
        media.emitLocalCandidate(ICECandidate(candidate: "cand:local", sdpMid: "0", sdpMLineIndex: 0))

        // Channel opens → the offer is sent with the right shape.
        channel.emit(.opened)
        let offerSent = await waitUntil { channel.sentFrames(ofType: "offer").count == 1 }
        XCTAssertTrue(offerSent, "offer is sent once the channel opens")
        let offer = channel.sentFrames(ofType: "offer").first!
        XCTAssertEqual(offer["authToken"] as? String, "tok")
        XCTAssertEqual(offer["mode"] as? String, "end-to-end")
        XCTAssertEqual((offer["data"] as? [String: Any])?["sdp"] as? String, media.offerSDP)
        XCTAssertEqual(channel.sentFrames(ofType: "ice-candidate").count, 0,
                       "local ICE stays buffered until the session id is known")

        // Answer arrives with a session id → applied, buffered ICE flushed.
        channel.emit(.message(answerFrame(sessionId: "sig_1", sdp: "v=0-answer")))
        let answerApplied = await waitUntil { media.acceptedAnswer == "v=0-answer" }
        XCTAssertTrue(answerApplied, "answer applied to media")
        let iceFlushed = await waitUntil { channel.sentFrames(ofType: "ice-candidate").count == 1 }
        XCTAssertTrue(iceFlushed, "buffered local ICE is flushed after the answer")
        XCTAssertEqual(channel.sentFrames(ofType: "ice-candidate").first?["sessionId"] as? String, "sig_1")

        // Remote ICE is forwarded to the media engine.
        channel.emit(.message(iceFrame(candidate: "cand:remote")))
        let remoteIce = await waitUntil { media.remoteCandidates.contains { $0.candidate == "cand:remote" } }
        XCTAssertTrue(remoteIce, "remote ICE forwarded to media engine")

        // Media connects → the call is connected.
        media.driveState(.connected)
        let isConnected = await waitUntil { await self.callState(coord) == .connected }
        XCTAssertTrue(isConnected, "call reaches connected")

        // End releases every resource.
        await coord.end()
        let ended = await waitUntil { await self.callState(coord) == .ended }
        XCTAssertTrue(ended)
        let tornDown = await waitUntil { media.closeCount == 1 && channel.closeCalled }
        XCTAssertTrue(tornDown, "media + signaling channel torn down on end")
    }

    // MARK: - Failure paths

    func test_createSessionFailure_failsAndThrows() async {
        let api = MockRestApi()
        api.createSessionResult = .failure(PolyError.transport(.networkError("boom")))
        let coord = makeCoordinator(api: api)

        do {
            try await coord.start()
            XCTFail("start() should rethrow the session failure")
        } catch {
            XCTAssertEqual(error as? PolyError, .transport(.networkError("boom")))
        }
        let state = await coord.state
        guard case .failed = state else { return XCTFail("expected failed, got \(state)") }
    }

    func test_signalingError_failsCall() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let coord = makeCoordinator(conn: conn, channel: channel)
        try await arm(coord, conn: conn)

        channel.emit(.opened)
        channel.emit(.message(errorFrame("bad token")))

        let failed = await waitUntil {
            if case .failed(.voice(.signalingFailed("bad token"))) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "signaling error fails the call")
    }

    func test_backendClose_endsCall() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let coord = makeCoordinator(conn: conn, channel: channel)
        try await arm(coord, conn: conn)

        channel.emit(.opened)
        channel.emit(.message(closeFrame()))

        let ended = await waitUntil { await self.callState(coord) == .ended }
        XCTAssertTrue(ended, "a backend close frame ends the call cleanly")
    }

    func test_signalingChannelClosed_failsCall() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let coord = makeCoordinator(conn: conn, channel: channel)
        try await arm(coord, conn: conn)

        channel.emit(.opened)
        channel.emit(.closed(code: 1006, reason: "abnormal"))

        let failed = await waitUntil {
            if case .failed(.voice(.signalingFailed)) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "an unexpected signaling close fails the call")
    }

    func test_mediaFailed_failsCall() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        channel.emit(.opened)

        media.driveState(.failed)
        let failed = await waitUntil {
            if case .failed(.voice(.mediaFailed)) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "a media failure fails the call")
    }

    func test_setMuted_forwardsToMediaEngine() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn)

        await coord.setMuted(true)
        XCTAssertEqual(media.muted, true)
        await coord.setMuted(false)
        XCTAssertEqual(media.muted, false)
    }

    // MARK: - Frame builders (return raw JSON Data wrapped at the call site)

    private func answerFrame(sessionId: String, sdp: String) -> Data {
        frameData(["type": "answer", "sessionId": sessionId, "data": ["type": "answer", "sdp": sdp]])
    }

    private func iceFrame(candidate: String) -> Data {
        frameData(["type": "ice-candidate", "data": ["candidate": candidate, "sdpMid": "0", "sdpMLineIndex": 0]])
    }

    private func errorFrame(_ message: String) -> Data {
        frameData(["type": "error", "data": ["message": message]])
    }

    private func closeFrame() -> Data {
        frameData(["type": "close"])
    }

    private func frameData(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
