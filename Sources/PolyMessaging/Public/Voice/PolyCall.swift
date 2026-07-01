// Copyright PolyAI Limited

import Foundation

/// Lifecycle state of a voice call.
public enum CallState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case ended
    case failed(PolyError)
}

public extension CallState {
    var isActive: Bool {
        switch self {
        case .connecting, .connected: return true
        default: return false
        }
    }
}

/// A voice call.
///
/// The base ``PolyMessaging/voice()`` factory ships **without** a media engine, so its
/// ``start()`` surfaces `PolyError.voice(.notImplemented)`. The **PolyVoice** product supplies
/// a real WebRTC audio engine — call `PolyVoice.call(config:options:)` to place audio calls
/// (it builds this via ``wired(config:webrtcToken:mediaEngine:)``).
public final class PolyCall: @unchecked Sendable {

    private let coordinator: CallCoordinator?
    private let config: Configuration?

    private let stateCaster = Multicaster<CallState>(replayLastValue: true)
    private let lock = NSLock()
    private var _state: CallState = .idle
    private var relayTask: Task<Void, Never>?

    /// Current call state.
    public var state: CallState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Call-state transitions. Late subscribers receive the current state.
    public var states: AsyncStream<CallState> { stateCaster.subscribe() }

    /// Public (gated) initializer: no media engine is bundled, so this call
    /// cannot carry audio yet. `start()` reports `.voice(.notImplemented)`.
    init(config: Configuration) {
        self.config = config
        self.coordinator = nil
    }

    /// Internal seam: drive a fully-wired pipeline (used by the test suite and
    /// the opt-in live integration probe with an injected media engine).
    init(coordinator: CallCoordinator) {
        self.config = nil
        self.coordinator = coordinator
        let stream = coordinator.stateStream
        relayTask = Task { [weak self] in
            for await newState in stream { self?.setState(newState) }
        }
    }

    deinit {
        relayTask?.cancel()
    }

    /// Begin the call. Voice calling is not yet available, so for the shipped
    /// SDK this throws `PolyError.voice(.notImplemented)`.
    public func start() async throws {
        guard let coordinator else {
            setState(.failed(.voice(.notImplemented)))
            throw PolyError.voice(.notImplemented)
        }
        try await coordinator.start()
    }

    /// End the call and release resources. Safe to call at any time.
    public func end() async {
        await coordinator?.end()
        if coordinator == nil { setState(.ended) }
    }

    /// Mute or unmute the local microphone.
    public func setMuted(_ muted: Bool) async {
        await coordinator?.setMuted(muted)
    }

    private func setState(_ newState: CallState) {
        lock.lock()
        _state = newState
        lock.unlock()
        stateCaster.emit(newState)
    }
}

public extension PolyCall {

    /// Build a fully-wired voice call driven by the supplied media engine.
    ///
    /// The base SDK ships no media engine, so `PolyMessaging.voice()` reports
    /// `.voice(.notImplemented)`. The **PolyVoice** product calls this with a
    /// WebRTC-backed ``CallMediaEngine`` to place real audio calls — it composes
    /// the same internal REST/session/signaling pipeline the tests exercise.
    ///
    /// - Parameters:
    ///   - config: the shared messaging `Configuration` (api key, environment, host).
    ///   - webrtcToken: the WebRTC gateway token (the offer `authToken` + ICE-servers auth).
    ///   - mediaEngine: the platform WebRTC engine that produces the SDP offer and carries audio.
    static func wired(config: Configuration, webrtcToken: String, mediaEngine: CallMediaEngine) -> PolyCall {
        let logger = OSLogLogger(level: config.logLevel)
        let urls = EnvironmentURLs(environment: config.environment)
        let hostId = config.hostIdentifier ?? Bundle.main.bundleIdentifier ?? ""
        let api = RestApi(
            baseURL: urls.restBaseURL,
            apiKey: config.apiKey,
            hostIdentifier: hostId,
            logger: logger
        )
        let linker = VoiceSessionLinker(
            connection: WebSocketTransport(logger: logger),
            wsBaseURL: urls.wsBaseURL,
            logger: logger
        )
        let voiceEnv = VoiceEnvironment(environment: config.environment)
        let channel = GatewaySignalingChannel(url: voiceEnv.signalingURL, logger: logger)
        let iceServers = GatewayIceServersFetcher(
            url: voiceEnv.iceServersURL(token: webrtcToken),
            logger: logger
        )
        let coordinator = CallCoordinator(
            api: api,
            linker: linker,
            channel: channel,
            media: mediaEngine,
            iceServers: iceServers,
            authToken: webrtcToken,
            streamingEnabled: config.streamingEnabled,
            logger: logger
        )
        return PolyCall(coordinator: coordinator)
    }
}
