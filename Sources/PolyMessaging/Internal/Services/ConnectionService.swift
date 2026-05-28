// Copyright PolyAI Limited

import Foundation

actor ConnectionService {

    private let transport: any Connection
    private let wsBaseURL: URL
    private let logger: PolyLogger

    private var currentSessionId: String?
    private var currentAccessToken: String?
    private var lastSequence: Int = 0
    private var reconnectAttempt: Int = 0
    private var maxReconnectAttempts: Int = 10
    private var invalidSessionReconnects: Int = 0
    private var shouldReconnect: Bool = true
    private var lastCloseWasNetwork: Bool = false
    private var currentAttemptOpened: Bool = false
    private var preserveBudgetOnNextConnect: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private(set) var connectionStartedAt: Date?

    // statusChanges is state-like: late subscribers should learn the current
    // connection status. The other streams are event-like (one-shot signals)
    // and replaying old events would mis-fire.
    nonisolated let statusChanges = Multicaster<ConnectionStatus>(replayLastValue: true)
    nonisolated let invalidSession = Multicaster<Void>()
    nonisolated let openEvents = Multicaster<Void>()
    nonisolated let closeEvents = Multicaster<ConnectionCloseEvent>()
    nonisolated let messageEvents = Multicaster<MessagingEvent>()
    nonisolated let batchEvents = Multicaster<[MessagingEvent]>()

    private static let maxBackoffSeconds: Double = 30
    private static let maxInvalidSessionAttempts = 3

    init(transport: any Connection, wsBaseURL: URL, logger: PolyLogger) {
        self.transport = transport
        self.wsBaseURL = wsBaseURL
        self.logger = logger
    }

    // MARK: - Connect

    func connectToSession(sessionId: String, accessToken: String) async {
        cancelReconnect()
        let isNewSession = sessionId != currentSessionId
        currentSessionId = sessionId
        currentAccessToken = accessToken
        if isNewSession { lastSequence = 0 }
        reconnectAttempt = 0
        // Preserve the invalid-session counter across a refetch chain when the flag is set
        // (AppCoordinator's onInvalidSession triggers refetchSession which calls connectToSession)
        if preserveBudgetOnNextConnect {
            preserveBudgetOnNextConnect = false
        } else {
            invalidSessionReconnects = 0
        }
        shouldReconnect = true
        lastCloseWasNetwork = false
        currentAttemptOpened = false

        let url = buildWSURL(sessionId: sessionId, accessToken: accessToken)
        statusChanges.emit(.connecting)
        logger.info("Connecting to session", metadata: ["sessionId": sessionId])

        await transport.connect(url: url)
        startObserving()
    }

    func disconnect(code: Int = 1000, reason: String = "normal") async {
        cancelReconnect()
        shouldReconnect = false
        statusChanges.emit(.closing)
        await transport.disconnect(code: code, reason: reason)
        statusChanges.emit(.closed(ConnectionCloseEvent(code: code, reason: reason, wasClean: code == 1000)))
    }

    func dropConnectionForReconnect(reason: String) async {
        await transport.disconnect(code: 1006, reason: reason)
    }

    func send(_ event: OutgoingEvent) async {
        await transport.send(event)
    }

    /// Awaits the transport reaching `.open`, returning `true` if it does
    /// within `timeout` seconds, or `false` if the deadline elapses first.
    /// Returns immediately if the transport is already `.open`.
    ///
    /// Used by `ChatService.retryIfPending` to back off briefly while a
    /// reconnect ladder is in flight rather than burning a retry slot on
    /// a `.notConnected` send.
    func waitForOpen(timeout: TimeInterval) async -> Bool {
        if case .open = await transport.status { return true }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [statusChanges] in
                for await status in statusChanges.subscribe() {
                    if case .open = status { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Live transport status. Used by Coordinator to gate per-tick heartbeat
    /// sends so frames aren't queued against a closed or connecting socket.
    func currentStatus() async -> ConnectionStatus {
        await transport.status
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func setMaxReconnectAttempts(_ n: Int) {
        maxReconnectAttempts = n
    }

    func resetReconnectBudget() {
        reconnectAttempt = 0
        shouldReconnect = true
    }

    func updateLastSequence(_ seq: Int) {
        if seq > lastSequence { lastSequence = seq }
    }

    func destroy() async {
        cancelReconnect()
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll()
        connectionStartedAt = nil
        shouldReconnect = false
        await transport.disconnect(code: 1000, reason: "SDK destroyed")
        statusChanges.finish()
        invalidSession.finish()
        openEvents.finish()
        closeEvents.finish()
        messageEvents.finish()
    }

    // MARK: - Observation

    private func startObserving() {
        // Cancel prior observation tasks to prevent duplicate message delivery on reconnect
        for task in observationTasks { task.cancel() }
        observationTasks.removeAll()

        let t1 = Task { [weak self] in
            guard let self else { return }
            for await _ in transport.openEvents {
                guard !Task.isCancelled else { break }
                await self.handleOpen()
            }
        }

        let t2 = Task { [weak self] in
            guard let self else { return }
            for await event in transport.closeEvents {
                guard !Task.isCancelled else { break }
                await self.handleClose(event)
            }
        }

        let t3 = Task { [weak self] in
            guard let self else { return }
            for await event in transport.messages {
                guard !Task.isCancelled else { break }
                self.messageEvents.emit(event)
            }
        }

        let t3b = Task { [weak self] in
            guard let self else { return }
            for await batch in transport.batchEvents {
                guard !Task.isCancelled else { break }
                self.batchEvents.emit(batch)
            }
        }

        // Bridge transport-level errors (non-UTF8 sends, binary-frame
        // receipts, etc.) into the service so observers don't miss
        // protocol-level failures that don't surface as close events.
        let t4 = Task { [weak self] in
            guard let self else { return }
            for await error in transport.errors {
                guard !Task.isCancelled else { break }
                self.logger.warn("Transport error", metadata: ["error": String(describing: error)])
                // Surface as synthetic close so the reconnect state machine
                // engages if the transport is in a broken state.
                self.closeEvents.emit(ConnectionCloseEvent(
                    code: 1006,
                    reason: "Transport error: \(error)",
                    wasClean: false
                ))
            }
        }

        observationTasks = [t1, t2, t3, t3b, t4]
    }

    // MARK: - Open

    private func handleOpen() {
        currentAttemptOpened = true
        reconnectAttempt = 0
        invalidSessionReconnects = 0
        connectionStartedAt = Date()
        cancelReconnect()
        statusChanges.emit(.open)
        openEvents.emit(())
        logger.info("WebSocket opened", metadata: nil)
    }

    // MARK: - Close

    private func handleClose(_ event: ConnectionCloseEvent) {
        connectionStartedAt = nil
        closeEvents.emit(event)

        let isHandshakeFailure = !currentAttemptOpened
            && event.code != 1000
            && event.code != 4000
            && event.code != 4001
            && event.code != 4003

        if isHandshakeFailure {
            logger.info("Handshake failure detected", metadata: ["code": String(event.code)])
            routeToInvalidSession()
            return
        }

        switch event.code {
        case 1000:
            statusChanges.emit(.closed(event))
            shouldReconnect = false
            logger.info("Normal close — no reconnect", metadata: nil)

        case 4000:
            logger.debug("Client replaced — ignoring", metadata: nil)

        case 1005, 1006, 4002:
            lastCloseWasNetwork = false
            scheduleReconnect()

        case 4003:
            lastCloseWasNetwork = true
            scheduleReconnect()

        case 4001:
            logger.info("Server rejected session", metadata: nil)
            routeToInvalidSession()

        default:
            scheduleReconnect()
        }
    }

    // MARK: - Reconnect

    private static let networkPollSeconds: Double = 10

    private func scheduleReconnect() {
        guard shouldReconnect, maxReconnectAttempts == 0 || reconnectAttempt < maxReconnectAttempts else {
            if maxReconnectAttempts > 0, reconnectAttempt >= maxReconnectAttempts {
                logger.warn("Max reconnect attempts exceeded", metadata: nil)
                shouldReconnect = false
                let terminalEvent = ConnectionCloseEvent(
                    code: 1006, reason: "Max reconnect attempts exceeded", wasClean: false
                )
                // Emit on BOTH closeEvents and statusChanges. Without the
                // closeEvents emit, Coordinator.observeConnectionClose never
                // receives the terminal close → UI shows "still connecting"
                // forever after the breaker trips.
                statusChanges.emit(.failed(reason: .transport(.networkError("Max reconnect attempts exceeded"))))
                closeEvents.emit(terminalEvent)
            }
            return
        }

        // Exponential backoff with ±20% jitter so a fleet-wide disconnect
        let delay: Double
        if lastCloseWasNetwork {
            delay = Self.networkPollSeconds
        } else {
            let base = min(Self.maxBackoffSeconds, pow(2.0, Double(reconnectAttempt)))
            delay = base * Double.random(in: 0.8...1.2)
        }
        reconnectAttempt += 1

        statusChanges.emit(.reconnecting(attempt: reconnectAttempt))
        logger.info("Reconnecting in \(delay)s", metadata: ["attempt": String(reconnectAttempt)])

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard let sid = await self.currentSessionId,
                  let token = await self.currentAccessToken else { return }
            await self.reconnect(sessionId: sid, accessToken: token)
        }
    }

    private func reconnect(sessionId: String, accessToken: String) async {
        currentAttemptOpened = false
        let url = buildWSURL(sessionId: sessionId, accessToken: accessToken)
        statusChanges.emit(.connecting)
        await transport.connect(url: url)
    }

    // MARK: - Invalid session

    private func routeToInvalidSession() {
        guard invalidSessionReconnects < Self.maxInvalidSessionAttempts else {
            shouldReconnect = false
            logger.warn("Too many invalid session reconnects — terminal", metadata: nil)
            let terminalEvent = ConnectionCloseEvent(
                code: 1006, reason: "Too many invalid session reconnects", wasClean: false
            )
            statusChanges.emit(.failed(reason: .session(.sessionExpired)))
            closeEvents.emit(terminalEvent)
            return
        }

        invalidSessionReconnects += 1
        preserveBudgetOnNextConnect = true
        invalidSession.emit(())
    }

    /// Called by Coordinator when session refetch fails — rolls back the budget
    /// so the next caller doesn't inherit a partially-spent counter.
    func notifyRefetchFailed() {
        invalidSessionReconnects = 0
        preserveBudgetOnNextConnect = false
    }

    // MARK: - URL

    private func buildWSURL(sessionId: String, accessToken: String) -> URL {
        var components = URLComponents(url: wsBaseURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "session_id", value: sessionId),
        ]
        if lastSequence > 0 {
            items.append(URLQueryItem(name: "cursor", value: "\(lastSequence)"))
        }
        components.queryItems = items
        return components.url!
    }
}
