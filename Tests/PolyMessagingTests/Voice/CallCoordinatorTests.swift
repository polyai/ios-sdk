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
        media: StubMediaEngine = StubMediaEngine(),
        connectionTimeoutNanos: UInt64 = 30_000_000_000, // long by default; per-test override
        disconnectGraceNanos: UInt64 = 300_000_000       // 300ms grace for tests
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
            logger: logger,
            connectionTimeoutNanos: connectionTimeoutNanos,
            disconnectGraceNanos: disconnectGraceNanos,
            reconnectBaseNanos: 20_000_000,           // 20ms — fast reconnect backoff for tests
            reconnectConnectTimeoutNanos: 400_000_000  // 400ms — fast connect wait for tests
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

        // The voice session-create carries platform + device_type for analytics.
        XCTAssertEqual(api.lastSessionContext?.platform, "ios")
        XCTAssertTrue(["mobile", "tablet", "desktop"].contains(api.lastSessionContext?.deviceType ?? ""))

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

    func test_signalingClose_reconnectsAndSurvives() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        channel.emit(.opened)
        media.driveState(.connected)
        _ = await waitUntil { await self.callState(coord) == .connected }

        // An unexpected close triggers a reconnect (the channel is re-opened).
        channel.emit(.closed(code: 1006, reason: "abnormal"))
        let reopened = await waitUntil { channel.openCount >= 2 }
        XCTAssertTrue(reopened, "an unexpected close triggers a reconnect")

        // The reconnect succeeds → the call survives (never transitions to failed).
        channel.emit(.opened)
        try? await Task.sleep(nanoseconds: 200_000_000)
        if case .failed = await self.callState(coord) {
            XCTFail("the call should survive a successful reconnect")
        }
    }

    func test_signalingReconnectExhausted_failsDisconnected() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        channel.emit(.opened)
        media.driveState(.connected)
        _ = await waitUntil { await self.callState(coord) == .connected }

        // The socket drops and never reconnects (no `.opened`) → after the retries
        // are exhausted the call fails as a (retryable) `.disconnected`.
        channel.emit(.closed(code: 1006, reason: "gone"))
        let failed = await waitUntil(timeout: 8) {
            if case .failed(.voice(.disconnected)) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "exhausted reconnects fail the call as .disconnected")
    }

    func test_reconnect_reflushesGapIce() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        channel.emit(.opened)
        channel.emit(.message(answerFrame(sessionId: "sig_1", sdp: "v=0"))) // sets the signal session id
        _ = await waitUntil { media.acceptedAnswer == "v=0" }
        media.driveState(.connected)
        _ = await waitUntil { await self.callState(coord) == .connected }

        // Socket drops → reconnect. A candidate generated during the gap must not be lost.
        channel.emit(.closed(code: 1006, reason: "gap"))
        _ = await waitUntil { channel.openCount >= 2 }
        media.emitLocalCandidate(ICECandidate(candidate: "cand:gap", sdpMid: "0", sdpMLineIndex: 0))
        channel.emit(.opened) // reconnect succeeds → buffered ICE is flushed

        let delivered = await waitUntil {
            channel.sentFrames(ofType: "ice-candidate")
                .contains { ($0["data"] as? [String: Any])?["candidate"] as? String == "cand:gap" }
        }
        XCTAssertTrue(delivered, "an ICE candidate from the reconnect gap is (re)sent after reconnect")
    }

    func test_iceServers_passedToEngine() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn)
        // Default provider → the STUN fallback reaches the engine's createOffer.
        XCTAssertEqual(media.lastIceServers, IceServer.default)
    }

    func test_mediaDropAfterConnect_failsDisconnected() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        channel.emit(.opened)
        media.driveState(.connected)
        _ = await waitUntil { await self.callState(coord) == .connected }

        // A hard media failure AFTER connecting is a retryable disconnect (not .mediaFailed).
        media.driveState(.failed)
        let failed = await waitUntil {
            if case .failed(.voice(.disconnected)) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "a drop after connecting surfaces .disconnected")
        XCTAssertTrue(PolyError.voice(.disconnected).isRetryable, ".disconnected is retryable")
    }

    // MARK: - Interruptions

    func test_interruption_transient_mutesThenRestores() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn)

        media.driveInterruption(.began)
        let muted = await waitUntil { media.muted == true }
        XCTAssertTrue(muted, "an interruption mutes the mic")

        media.driveInterruption(.endedResume)
        let unmuted = await waitUntil { media.muted == false }
        XCTAssertTrue(unmuted, "a resumable end unmutes")
    }

    func test_interruption_preservesUserMute() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn)

        await coord.setMuted(true)              // user mutes
        media.driveInterruption(.began)         // interruption also mutes
        media.driveInterruption(.endedResume)   // interruption ends...
        // ...the mic stays muted because the user muted it.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(media.muted, true, "the user's mute survives an interruption cycle")
    }

    func test_interruption_nonResumable_endsCall() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn)

        media.driveInterruption(.endedStop)
        let failed = await waitUntil {
            if case .failed(.voice(.interrupted)) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "a non-resumable interruption ends the call as .interrupted")
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

    // MARK: - Audio device API

    func test_isMuted_reflectsSetMuted() async throws {
        let conn = MockConnection()
        let coord = makeCoordinator(conn: conn)
        try await arm(coord, conn: conn)
        await coord.setMuted(true)
        var muted = await coord.isMuted
        XCTAssertTrue(muted)
        await coord.setMuted(false)
        muted = await coord.isMuted
        XCTAssertFalse(muted)
    }

    func test_selectAudioDevice_forwardsToEngine() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn)
        let speaker = AudioDevice(type: .speakerphone, name: "Speaker", id: "builtin.speaker")
        await coord.selectAudioDevice(speaker)
        await coord.selectAudioDevice(nil) // revert to automatic
        XCTAssertEqual(media.audioDeviceSelections.count, 2)
        XCTAssertEqual(media.audioDeviceSelections.first ?? nil, speaker)
        XCTAssertNil(media.audioDeviceSelections.last!)
    }

    func test_audioState_relayedToStream() async throws {
        let conn = MockConnection()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, media: media)
        try await arm(coord, conn: conn) // sets the audio-state handler
        let device = AudioDevice(type: .bluetooth, name: "Buds", id: "bt1")
        let state = AudioState(availableDevices: [device], selectedDevice: device)

        let stream = coord.audioStream
        media.driveAudioState(state)
        var received: AudioState?
        let deadline = Date().addingTimeInterval(2)
        for await snapshot in stream {
            received = snapshot
            if snapshot == state || Date() > deadline { break }
        }
        XCTAssertEqual(received, state, "engine audio-state snapshots reach PolyCall's audio stream")
    }

    // MARK: - Timeout / grace / inbound buffering / graceful close

    func test_connectionTimeout_failsTimedOut() async throws {
        let conn = MockConnection()
        let coord = makeCoordinator(conn: conn, connectionTimeoutNanos: 300_000_000)
        try await arm(coord, conn: conn) // armed but never connects
        let failed = await waitUntil(timeout: 3) {
            if case .failed(.voice(.timedOut)) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "an un-connected call fails with .timedOut")
    }

    func test_disconnect_recoversWithinGrace_staysConnected() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media, disconnectGraceNanos: 1_000_000_000)
        try await arm(coord, conn: conn)
        channel.emit(.opened)
        media.driveState(.connected)
        _ = await waitUntil { await self.callState(coord) == .connected }

        media.driveState(.disconnected) // a transient blip…
        media.driveState(.connected)    // …that recovers within the grace window
        try? await Task.sleep(nanoseconds: 200_000_000)
        let recovered = await self.callState(coord)
        XCTAssertEqual(recovered, .connected, "a blip that recovers within grace stays connected")
    }

    func test_inboundIce_bufferedUntilAnswer() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let coord = makeCoordinator(conn: conn, channel: channel, media: media)
        try await arm(coord, conn: conn)
        channel.emit(.opened)

        // A remote candidate BEFORE the answer must be buffered, not added to the peer.
        channel.emit(.message(iceFrame(candidate: "cand:early")))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(media.remoteCandidates.isEmpty, "remote ICE is buffered until the answer is applied")

        // Answer applied → the buffered candidate is flushed to the peer.
        channel.emit(.message(answerFrame(sessionId: "sig_1", sdp: "v=0")))
        let flushed = await waitUntil { media.remoteCandidates.contains { $0.candidate == "cand:early" } }
        XCTAssertTrue(flushed, "buffered remote ICE is added after the answer")
    }

    func test_failure_sendsGracefulCloseFrame() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let coord = makeCoordinator(conn: conn, channel: channel)
        try await arm(coord, conn: conn)
        channel.emit(.opened)
        channel.emit(.message(answerFrame(sessionId: "sig_1", sdp: "v=0"))) // sets the session id
        _ = await waitUntil { channel.sentFrames(ofType: "offer").count == 1 }

        channel.emit(.message(errorFrame("boom"))) // fail the call
        let closed = await waitUntil { channel.sentFrames(ofType: "close").count == 1 }
        XCTAssertTrue(closed, "a failure sends a graceful close frame")
    }

    func test_signalingReconnectExhausted_beforeConnected_failsSignaling() async throws {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let coord = makeCoordinator(conn: conn, channel: channel)
        try await arm(coord, conn: conn)
        channel.emit(.opened) // opened but never media-connected

        channel.emit(.closed(code: 1006, reason: "gone"))
        let failed = await waitUntil(timeout: 8) {
            if case .failed(.voice(.signalingFailed)) = await self.callState(coord) { return true }
            return false
        }
        XCTAssertTrue(failed, "a pre-connect reconnect exhaustion fails as .signalingFailed")
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
