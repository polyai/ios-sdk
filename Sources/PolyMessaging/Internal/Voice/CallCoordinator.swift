// Copyright PolyAI Limited

import Foundation

/// Orchestrates the full voice-call lifecycle, composing the REST auth/session
/// API, the messaging-session linker, the signaling channel and the media
/// engine. Composes the REST auth, signaling channel, and media engine.
///
/// Pipeline (mirrors the web client and verified end-to-end against the live
/// gateway):
///   1. obtain access token            (`RestApiPort.obtainAccessToken`)
///   2. create messaging session       (`RestApiPort.createSession`)
///   3. open messaging WS + link call  (`VoiceSessionLinker`)
///   4. open signaling WS              (`SignalingChannel`)
///   5. create + send the SDP offer    (`CallMediaEngine` → gateway)
///   6. apply the answer, exchange ICE (gateway ↔ `CallMediaEngine`)
///   7. media connects → `.connected`
actor CallCoordinator {

    private let api: RestApiPort
    private let linker: VoiceSessionLinker
    private let channel: SignalingChannel
    private let media: CallMediaEngine
    private let iceServersProvider: IceServersProviding
    private let authToken: String
    private let streamingEnabled: Bool
    private let logger: PolyLogger

    private let stateCaster = Multicaster<CallState>(replayLastValue: true)
    private let audioCaster = Multicaster<AudioState>(replayLastValue: true)
    private(set) var state: CallState = .idle

    private var active = false
    private var callSid: String?
    private var signalSessionId: String?
    private var pendingOfferSDP: String?
    private var pendingLocalIce: [ICECandidate] = []
    private var pendingRemoteIce: [ICECandidate] = []
    private var remoteAnswerApplied = false
    private var lastMediaState: CallMediaState = .new
    private var hasConnected = false
    private var userMuted = false
    private var interruptionMuted = false

    private var eventLoopTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var disconnectGraceTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var signalingReconnecting = false
    private var signalingConnected = false

    private let connectionTimeoutNanos: UInt64
    private let disconnectGraceNanos: UInt64
    private static let maxSignalingReconnects = 3
    private let signalingReconnectBaseNanos: UInt64
    private let signalingConnectTimeoutNanos: UInt64

    init(
        api: RestApiPort,
        linker: VoiceSessionLinker,
        channel: SignalingChannel,
        media: CallMediaEngine,
        iceServers: IceServersProviding = StaticIceServersProvider(),
        authToken: String,
        streamingEnabled: Bool,
        logger: PolyLogger,
        connectionTimeoutNanos: UInt64 = 30_000_000_000,
        disconnectGraceNanos: UInt64 = 5_000_000_000,
        reconnectBaseNanos: UInt64 = 1_000_000_000,
        reconnectConnectTimeoutNanos: UInt64 = 5_000_000_000
    ) {
        self.api = api
        self.linker = linker
        self.channel = channel
        self.media = media
        self.iceServersProvider = iceServers
        self.authToken = authToken
        self.streamingEnabled = streamingEnabled
        self.logger = logger
        self.connectionTimeoutNanos = connectionTimeoutNanos
        self.disconnectGraceNanos = disconnectGraceNanos
        self.signalingReconnectBaseNanos = reconnectBaseNanos
        self.signalingConnectTimeoutNanos = reconnectConnectTimeoutNanos
    }

    /// Late subscribers receive the current state immediately.
    nonisolated var stateStream: AsyncStream<CallState> { stateCaster.subscribe() }
    nonisolated var audioStream: AsyncStream<AudioState> { audioCaster.subscribe() }

    // MARK: - Lifecycle

    func start() async throws {
        guard !active else { return }
        active = true
        setState(.connecting)

        await media.setLocalCandidateHandler { [weak self] candidate in
            Task { await self?.handleLocalCandidate(candidate) }
        }
        await media.setStateHandler { [weak self] mediaState in
            Task { await self?.handleMediaState(mediaState) }
        }
        await media.setInterruptionHandler { [weak self] interruption in
            Task { await self?.handleInterruption(interruption) }
        }
        await media.setAudioStateHandler { [weak self] audioState in
            Task { await self?.emitAudioState(audioState) }
        }

        startConnectTimeout()

        do {
            let token = try await api.obtainAccessToken().accessToken
            try ensureActive()

            let session = try await api.createSession(
                context: SessionContext(
                    platform: "ios",
                    deviceType: DeviceTypeDetector.detect().rawValue,
                    streamingEnabled: streamingEnabled
                )
            )
            try ensureActive()

            let sid = UUID().uuidString
            callSid = sid
            try await linker.open(accessToken: token, sessionId: session.sessionId, callSid: sid)
            try ensureActive()

            // Fetch STUN/TURN from the gateway (best-effort → STUN fallback) so calls
            // behind symmetric NAT / CGNAT get a relay candidate.
            let iceServers = await iceServersProvider.fetch()
            try ensureActive()

            let offer = try await media.createOffer(iceServers: iceServers)
            try ensureActive()
            pendingOfferSDP = offer

            // Subscribe to the channel BEFORE opening so `.opened` isn't missed;
            // the offer is sent from the event loop when `.opened` arrives.
            startSignalingLoop()
            await channel.open()

            logger.debug("Voice call pipeline armed", metadata: ["callSid": sid])
        } catch {
            let mapped = mapError(error)
            fail(mapped)
            throw mapped
        }
    }

    func end() {
        guard active else { return }
        logger.debug("Voice call ending", metadata: nil)
        teardown()
        setState(.ended)
    }

    func setMuted(_ muted: Bool) async {
        userMuted = muted
        await applyMicState()
    }

    var isMuted: Bool { userMuted }

    /// Route call audio to `device`, or `nil` for automatic routing.
    func selectAudioDevice(_ device: AudioDevice?) async {
        await media.selectAudioDevice(device)
    }

    private func emitAudioState(_ state: AudioState) {
        audioCaster.emit(state)
    }

    /// The mic is off when the user muted OR an interruption is muting it — so an
    /// interruption never overrides (or is overridden by) the user's mute intent.
    private func applyMicState() async {
        await media.setMuted(userMuted || interruptionMuted)
    }

    /// React to an audio-session interruption.
    /// A transient loss mutes the mic; a resumable end restores it (respecting the
    /// user's mute); a non-resumable end ends the call as `.interrupted`.
    private func handleInterruption(_ interruption: CallInterruption) async {
        guard active else { return }
        switch interruption {
        case .began:
            interruptionMuted = true
            await applyMicState()
        case .endedResume:
            interruptionMuted = false
            await applyMicState()
        case .endedStop:
            logger.debug("Audio interrupted — ending call", metadata: nil)
            fail(.voice(.interrupted))
        }
    }

    // MARK: - Signaling

    private func startSignalingLoop() {
        eventLoopTask?.cancel()
        let channel = self.channel
        eventLoopTask = Task { [weak self] in
            for await event in channel.events {
                await self?.handleChannelEvent(event)
            }
        }
    }

    private func handleChannelEvent(_ event: SignalingChannelEvent) async {
        switch event {
        case .opened:
            signalingConnected = true
            if signalingReconnecting {
                // A reconnect succeeded — the gateway routes by sessionId, so re-flush
                // any ICE buffered during the gap rather than re-offering.
                await flushLocalIce()
            } else {
                await sendPendingOffer()
            }
        case .message(let data):
            if let signal = SignalingProtocol.parse(data) { await handle(signal) }
        case .closed(let code, _):
            logger.warn("Signaling connection closed (\(code))", metadata: nil)
            signalingConnected = false
            handleSignalingDrop()
        case .failed(let underlying):
            logger.error("Signaling channel failed", metadata: ["error": String(describing: underlying)])
            signalingConnected = false
            handleSignalingDrop()
        }
    }

    /// The signaling socket dropped unexpectedly. Reconnect with exponential backoff
    /// (1s/2s/4s, up to `maxSignalingReconnects`) on the same session, re-flushing any
    /// ICE buffered during the gap. Only fail once every attempt is exhausted.
    private func handleSignalingDrop() {
        guard active, !signalingReconnecting else { return } // a drop mid-reconnect is the loop's job
        signalingReconnecting = true
        reconnectTask = Task { [weak self] in await self?.reconnectSignaling() }
    }

    private func reconnectSignaling() async {
        for attempt in 1...Self.maxSignalingReconnects {
            try? await Task.sleep(nanoseconds: signalingReconnectBaseNanos << (attempt - 1))
            guard active else { signalingReconnecting = false; return }
            logger.debug("Reconnecting signaling", metadata: ["attempt": "\(attempt)"])
            await channel.open()
            if await waitForSignalingConnect() {
                logger.debug("Signaling reconnected", metadata: nil)
                signalingReconnecting = false
                return
            }
        }
        signalingReconnecting = false
        guard active else { return }
        logger.error("Signaling reconnect exhausted", metadata: nil)
        // Once connected, the media path is what was lost; before connect, the handshake
        // never completed — surface the more precise error in each case.
        fail(hasConnected ? .voice(.disconnected) : .voice(.signalingFailed("Signaling connection lost")))
    }

    /// Wait (up to ~5s) for the reconnected socket's `.opened` — handled on this actor,
    /// so a `Task.sleep` here lets that event run and flip `signalingConnected`.
    private func waitForSignalingConnect() async -> Bool {
        let step: UInt64 = 100_000_000 // 100ms
        var waited: UInt64 = 0
        while waited < signalingConnectTimeoutNanos {
            if !active { return false }
            if signalingConnected { return true }
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
        return signalingConnected
    }

    private func sendPendingOffer() async {
        guard active, let sdp = pendingOfferSDP, let sid = callSid else { return }
        pendingOfferSDP = nil
        guard let data = SignalingProtocol.offer(
            sdp: sdp, authToken: authToken, callSid: sid, sessionId: signalSessionId
        ) else {
            fail(.voice(.signalingFailed("Failed to encode offer")))
            return
        }
        await channel.send(data)
        logger.debug("Voice offer sent — awaiting answer", metadata: nil)
    }

    private func handle(_ signal: InboundSignal) async {
        switch signal {
        case .answer(let sessionId, let sdp):
            if let sessionId {
                signalSessionId = sessionId
                await flushLocalIce()
            }
            do {
                try await media.acceptAnswer(sdp: sdp)
                remoteAnswerApplied = true
                await flushRemoteIce()
            } catch {
                fail(.voice(.mediaFailed("Failed to apply answer: \(error.localizedDescription)")))
            }
        case .iceCandidate(let candidate):
            // A remote candidate that arrives before the answer is applied can't be added
            // yet (the peer has no remote description) — buffer it until acceptAnswer.
            if remoteAnswerApplied {
                try? await media.addRemoteCandidate(candidate)
            } else {
                pendingRemoteIce.append(candidate)
            }
        case .error(let message):
            fail(.voice(.signalingFailed(message)))
        case .pong:
            break
        case .close:
            end()
        }
    }

    // MARK: - ICE

    private func handleLocalCandidate(_ candidate: ICECandidate) async {
        guard active else { return }
        // Buffer until the session id is known, and also while the signaling socket is
        // reconnecting — otherwise a candidate would be sent into a dead socket and lost.
        // flushLocalIce() re-sends the buffer once the (re)connected socket is ready.
        if let sid = signalSessionId, !signalingReconnecting {
            if let data = SignalingProtocol.iceCandidate(candidate, sessionId: sid) {
                await channel.send(data)
            }
        } else {
            pendingLocalIce.append(candidate)
        }
    }

    private func flushLocalIce() async {
        guard let sid = signalSessionId, !pendingLocalIce.isEmpty else { return }
        for candidate in pendingLocalIce {
            if let data = SignalingProtocol.iceCandidate(candidate, sessionId: sid) {
                await channel.send(data)
            }
        }
        pendingLocalIce.removeAll()
    }

    /// Add remote candidates buffered before the answer was applied, in arrival order.
    private func flushRemoteIce() async {
        guard !pendingRemoteIce.isEmpty else { return }
        let buffered = pendingRemoteIce
        pendingRemoteIce.removeAll()
        for candidate in buffered {
            try? await media.addRemoteCandidate(candidate)
        }
    }

    // MARK: - Media state

    private func handleMediaState(_ mediaState: CallMediaState) async {
        guard active else { return }
        lastMediaState = mediaState
        switch mediaState {
        case .connected:
            hasConnected = true
            cancelConnectTimeout()
            disconnectGraceTask?.cancel()
            disconnectGraceTask = nil
            setState(.connected)
        case .failed:
            // A drop after connecting is a (retryable) disconnect; a failure before
            // ever connecting is a hard media failure.
            fail(hasConnected ? .voice(.disconnected) : .voice(.mediaFailed("Peer connection failed")))
        case .disconnected:
            startDisconnectGrace()
        case .new, .connecting, .closed:
            break
        }
    }

    private func startDisconnectGrace() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: disconnectGraceNanos)
            await self?.failIfStillDisconnected()
        }
    }

    private func failIfStillDisconnected() {
        guard active else { return }
        if lastMediaState == .disconnected || lastMediaState == .failed {
            // Grace only starts after the media had connected, so this is a drop.
            fail(.voice(.disconnected))
        }
    }

    // MARK: - Timeout

    private func startConnectTimeout() {
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: connectionTimeoutNanos)
            await self?.failOnTimeout()
        }
    }

    private func failOnTimeout() {
        guard active, state == .connecting else { return }
        logger.error("Voice call connection timed out", metadata: nil)
        fail(.voice(.timedOut))
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    // MARK: - Teardown

    private func fail(_ error: PolyError) {
        guard active else { return }
        logger.error("Voice call failed", metadata: ["error": String(describing: error)])
        teardown()
        setState(.failed(error))
    }

    private func teardown() {
        active = false
        cancelConnectTimeout()
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
        eventLoopTask?.cancel()
        eventLoopTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        signalingReconnecting = false

        let sid = signalSessionId
        let channel = self.channel
        let linker = self.linker
        let media = self.media
        Task {
            if let sid, let data = SignalingProtocol.close(sessionId: sid) {
                await channel.send(data)
            }
            await channel.close()
            await linker.close()
            await media.close()
        }

        signalSessionId = nil
        pendingOfferSDP = nil
        pendingLocalIce.removeAll()
        pendingRemoteIce.removeAll()
        remoteAnswerApplied = false
    }

    // MARK: - Helpers

    private func ensureActive() throws {
        if !active { throw PolyError.voice(.signalingFailed("Call ended before it connected")) }
    }

    private func setState(_ newState: CallState) {
        state = newState
        stateCaster.emit(newState)
    }

    private func mapError(_ error: Error) -> PolyError {
        if let polyError = error as? PolyError { return polyError }
        return .voice(.signalingFailed(error.localizedDescription))
    }
}
