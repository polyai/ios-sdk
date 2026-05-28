// Copyright PolyAI Limited

import Foundation

public final class PolyMessagingClient: @unchecked Sendable {

    public let config: Configuration

    private let coordinator: Coordinator
    private let transport: WebSocketTransport
    private let sessionService: SessionService
    private let lock = NSLock()
    private var startTask: Task<Void, Error>?

    public var events: AsyncStream<MessagingEvent> {
        coordinator.events.subscribe()
    }

    public var connectionStatus: AsyncStream<ConnectionStatus> {
        coordinator.connectionStatus.subscribe()
    }

    /// Session lifecycle state. Late subscribers receive the current value.
    public var sessionState: AsyncStream<SessionState> {
        sessionService.stateChanges.subscribe()
    }

    public func send(_ text: String) async throws {
        try await ensureStartedAsync()
        try await coordinator.send(text)
    }

    /// Signal the user is typing. Safe to call on every keystroke — the SDK
    /// throttles STARTED frames and auto-sends STOPPED after inactivity.
    public func sendTyping() async throws {
        try await ensureStartedAsync()
        await coordinator.sendTyping()
    }

    public func end(reason: String? = "user_ended") async throws {
        await coordinator.end(reason: reason)
    }

    /// Resume a prior session or create a fresh one. Idempotent.
    public func resume() async throws {
        try await ensureStartedAsync()
    }

    /// Start a brand-new session, discarding any persisted state.
    public func startNewSession() async throws {
        try await startTask?.value
        await coordinator.startNewSession()
    }

    /// Tear down the SDK. Idempotent. After shutdown, create a new client.
    public func shutdown() async {
        let alreadyShutdown: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if shutdownComplete { return true }
            shutdownComplete = true
            return false
        }()
        guard !alreadyShutdown else { return }
        startTask?.cancel()
        await coordinator.destroy()
    }

    private var shutdownComplete = false

    public func getConnection() -> any Connection {
        transport
    }

    /// Create a voice call on this connector. Call `start()` on the result to
    /// place it.
    ///
    /// Voice calling is not yet available: the SDK ships without an on-device
    /// media (WebRTC audio) engine, so `start()` surfaces
    /// `PolyError.voice(.notImplemented)`.
    public func voice() -> PolyCall {
        PolyCall(config: config)
    }

    // MARK: - Internal

    init(config: Configuration) {
        self.config = config

        let logger = OSLogLogger(level: config.logLevel)
        let urls = EnvironmentURLs(environment: config.environment)
        let resolvedHostId = config.hostIdentifier ?? Bundle.main.bundleIdentifier ?? ""
        let api = RestApi(baseURL: urls.restBaseURL, apiKey: config.apiKey, hostIdentifier: resolvedHostId, logger: logger)
        let transport = WebSocketTransport(logger: logger)
        self.transport = transport

        let sessionService = SessionService(api: api, config: config, logger: logger)
        self.sessionService = sessionService
        let connectionService = ConnectionService(transport: transport, wsBaseURL: urls.wsBaseURL, logger: logger)
        if let maxAttempts = config.maxReconnectAttempts, maxAttempts > 0 {
            Task { await connectionService.setMaxReconnectAttempts(maxAttempts) }
        }
        let chatService = ChatService(logger: logger)
        let heartbeatService = HeartbeatService(intervalSeconds: config.heartbeatIntervalSeconds ?? 30)

        self.coordinator = Coordinator(
            sessionService: sessionService,
            connectionService: connectionService,
            chatService: chatService,
            heartbeatService: heartbeatService,
            logger: logger
        )

        startTask = Task { try await coordinator.start() }
    }

    /// Test seam: build a client over an already-assembled coordinator (e.g.
    /// backed by a `MockConnection`/`MockRestApi`) so `ChatSession` can be
    /// driven deterministically without a real network. Not public; no effect
    /// on the production `init(config:)` path.
    init(
        coordinator: Coordinator,
        sessionService: SessionService,
        transport: WebSocketTransport,
        config: Configuration,
        autoStart: Bool = true
    ) {
        self.config = config
        self.coordinator = coordinator
        self.sessionService = sessionService
        self.transport = transport
        if autoStart {
            startTask = Task { try await coordinator.start() }
        }
    }

    // MARK: - Start gate

    private func ensureStartedAsync() async throws {
        try await startTask?.value
    }
}
