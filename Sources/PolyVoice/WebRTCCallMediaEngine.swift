// Copyright PolyAI Limited

#if os(iOS)
import Foundation
import WebRTC
@_spi(PolyVoice) import PolyMessaging

/// Real WebRTC audio engine.
///
/// Audio-only (Opus), Unified Plan, trickle ICE. Bridges WebRTC's completion-handler
/// API into the `async` `CallMediaEngine` seam the `CallCoordinator` drives.
final class WebRTCCallMediaEngine: NSObject, CallMediaEngine, @unchecked Sendable {

    // One factory per process; RTCInitializeSSL is required once before use.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let audio: AudioSessionController
    private let lock = NSLock()
    private var peer: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    // Latched by close(). createOffer() suspends (offer creation, setLocalDescription)
    // and only publishes `peer` at the end, so a close() landing in that window would
    // otherwise find `peer == nil`, release nothing, and leave the connection it never
    // saw running with a live mic track. Every publish point re-checks this latch.
    private var closed = false
    private var localCandidateHandler: (@Sendable (IceCandidate) -> Void)?
    private var stateHandler: (@Sendable (CallMediaState) -> Void)?

    init(audio: AudioSessionController) {
        self.audio = audio
        super.init()
    }

    // MARK: - CallMediaEngine

    func createOffer(iceServers: [IceServer]) async throws -> String {
        // Manual-vs-automatic audio must be decided BEFORE the first audio track
        // exists (WebRTC starts the audio unit at track-ready time otherwise).
        // The flag is process-global, so a non-CallKit call must also RESET it —
        // a leftover `true` from a previous CallKit call would leave this call
        // waiting forever for a didActivate that never comes.
        //
        // Do NOT touch `isAudioEnabled` here: callKitConfigureAudioSession() gates
        // it off before the call and didActivate opens it — and because signaling
        // takes seconds, CallKit has usually ALREADY activated by the time this
        // runs. Re-gating here would stomp that activation and silence the call.
        // Already ended before setup even began — don't touch the process-global
        // audio session or build a peer nobody will ever close.
        try checkNotClosed()

        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.useManualAudio = audio.callKitMode

        audio.activate() // configure (and, without CallKit, activate) the AVAudioSession

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        // Gateway-provided STUN/TURN (falls back to public STUN when the fetch failed);
        // TURN entries carry credentials, STUN entries don't.
        config.iceServers = (iceServers.isEmpty ? IceServer.defaultServers : iceServers).map { server in
            if let username = server.username, let credential = server.credential {
                return RTCIceServer(urlStrings: server.urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: server.urls)
        }

        let empty = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: config, constraints: empty, delegate: self) else {
            throw PolyError.voice(.mediaFailed("could not create the WebRTC peer connection"))
        }

        // Local microphone track (Opus).
        let source = Self.factory.audioSource(with: empty)
        let track = Self.factory.audioTrack(with: source, trackId: "audio0")
        peer.add(track, streamIds: ["stream0"])

        // Publish under the same lock that reads `closed`, so a close() either sees
        // this peer (and releases it) or has already latched (and we release it here).
        lock.lock()
        if closed {
            lock.unlock()
            peer.close()
            audio.deactivate()
            throw PolyError.voice(.mediaFailed("call ended during setup"))
        }
        self.peer = peer
        self.audioTrack = track
        lock.unlock()

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"],
            optionalConstraints: nil
        )
        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            peer.offer(for: offerConstraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? PolyError.voice(.mediaFailed("offer creation failed"))) }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return offer.sdp
    }

    func acceptAnswer(sdp: String) async throws {
        guard let peer = currentPeer() else { throw PolyError.voice(.mediaFailed("no active peer connection")) }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(answer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func addRemoteCandidate(_ candidate: IceCandidate) async throws {
        guard let peer = currentPeer() else { return }
        let rtc = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
            sdpMid: candidate.sdpMid
        )
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.add(rtc) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func setLocalCandidateHandler(_ handler: @escaping @Sendable (IceCandidate) -> Void) async {
        lock.lock(); localCandidateHandler = handler; lock.unlock()
    }

    func setStateHandler(_ handler: @escaping @Sendable (CallMediaState) -> Void) async {
        lock.lock(); stateHandler = handler; lock.unlock()
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable (CallInterruption) -> Void) async {
        // The AVAudioSession interruption observer lives in the audio controller.
        audio.setInterruptionSink(handler)
    }

    func setAudioStateHandler(_ handler: @escaping @Sendable (AudioState) -> Void) async {
        audio.setAudioStateSink(handler)
    }

    func selectAudioDevice(_ device: AudioDevice?) async {
        audio.select(device)
    }

    func setMuted(_ muted: Bool) async {
        lock.lock(); let track = audioTrack; lock.unlock()
        track?.isEnabled = !muted
    }

    func close() async {
        lock.lock()
        closed = true // latch first: a createOffer() still in flight will release its own peer
        let peer = self.peer
        self.peer = nil
        self.audioTrack = nil
        lock.unlock()
        peer?.close()
        if audio.callKitMode {
            // Defensive: if the call died without CallKit deactivating (e.g. a
            // signaling failure before the system ever activated), make sure the
            // audio unit can't start later on a dead call.
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        }
        audio.deactivate()
    }

    // MARK: - Helpers

    private func currentPeer() -> RTCPeerConnection? {
        lock.lock(); defer { lock.unlock() }; return peer
    }

    private func checkNotClosed() throws {
        lock.lock(); let isClosed = closed; lock.unlock()
        if isClosed { throw PolyError.voice(.mediaFailed("call ended during setup")) }
    }

    private func emitState(_ state: CallMediaState) {
        lock.lock(); let handler = stateHandler; lock.unlock()
        handler?(state)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCCallMediaEngine: RTCPeerConnectionDelegate {

    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        lock.lock(); let handler = localCandidateHandler; lock.unlock()
        handler?(IceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        ))
    }

    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .new: emitState(.new)
        case .connecting: emitState(.connecting)
        case .connected: emitState(.connected)
        case .disconnected: emitState(.disconnected)
        case .failed: emitState(.failed)
        case .closed: emitState(.closed)
        @unknown default: break
        }
    }

    // Unused delegate requirements.
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
#endif
