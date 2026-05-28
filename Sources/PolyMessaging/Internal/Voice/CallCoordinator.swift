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
    private let authToken: String
    private let streamingEnabled: Bool
    private let logger: PolyLogger

    private let stateCaster = Multicaster<CallState>(replayLastValue: true)
    private(set) var state: CallState = .idle

    private var active = false
    private var callSid: String?
    private var signalSessionId: String?
    private var pendingOfferSDP: String?
    private var pendingLocalIce: [ICECandidate] = []
    private var lastMediaState: CallMediaState = .new

    private var eventLoopTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var disconnectGraceTask: Task<Void, Never>?

    private static let connectionTimeoutNanos: UInt64 = 30_000_000_000
    private static let disconnectGraceNanos: UInt64 = 5_000_000_000

    init(
        api: RestApiPort,
        linker: VoiceSessionLinker,
        channel: SignalingChannel,
        media: CallMediaEngine,
        authToken: String,
        streamingEnabled: Bool,
        logger: PolyLogger
    ) {
        self.api = api
        self.linker = linker
        self.channel = channel
        self.media = media
        self.authToken = authToken
        self.streamingEnabled = streamingEnabled
        self.logger = logger
    }

    /// Late subscribers receive the current state immediately.
    nonisolated var stateStream: AsyncStream<CallState> { stateCaster.subscribe() }

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

        startConnectTimeout()

        do {
            let token = try await api.obtainAccessToken().accessToken
            try ensureActive()

            let session = try await api.createSession(
                context: SessionContext(platform: "ios", streamingEnabled: streamingEnabled)
            )
            try ensureActive()

            let sid = UUID().uuidString
            callSid = sid
            try await linker.open(accessToken: token, sessionId: session.sessionId, callSid: sid)
            try ensureActive()

            let offer = try await media.createOffer()
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
        await media.setMuted(muted)
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
            await sendPendingOffer()
        case .message(let data):
            if let signal = SignalingProtocol.parse(data) { await handle(signal) }
        case .closed(let code, _):
            if active { fail(.voice(.signalingFailed("Signaling connection closed (\(code))"))) }
        case .failed(let underlying):
            logger.error("Signaling channel failed", metadata: ["error": String(describing: underlying)])
            if active { fail(.voice(.signalingFailed("Signaling connection lost"))) }
        }
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
            } catch {
                fail(.voice(.mediaFailed("Failed to apply answer: \(error.localizedDescription)")))
            }
        case .iceCandidate(let candidate):
            try? await media.addRemoteCandidate(candidate)
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
        if let sid = signalSessionId {
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

    // MARK: - Media state

    private func handleMediaState(_ mediaState: CallMediaState) async {
        guard active else { return }
        lastMediaState = mediaState
        switch mediaState {
        case .connected:
            cancelConnectTimeout()
            disconnectGraceTask?.cancel()
            disconnectGraceTask = nil
            setState(.connected)
        case .failed:
            fail(.voice(.mediaFailed("Peer connection failed")))
        case .disconnected:
            startDisconnectGrace()
        case .new, .connecting, .closed:
            break
        }
    }

    private func startDisconnectGrace() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.disconnectGraceNanos)
            await self?.failIfStillDisconnected()
        }
    }

    private func failIfStillDisconnected() {
        guard active else { return }
        if lastMediaState == .disconnected || lastMediaState == .failed {
            fail(.voice(.mediaFailed("Peer connection disconnected")))
        }
    }

    // MARK: - Timeout

    private func startConnectTimeout() {
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectionTimeoutNanos)
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
