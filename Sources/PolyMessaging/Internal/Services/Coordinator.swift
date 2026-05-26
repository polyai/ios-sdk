// Copyright PolyAI Limited

import Foundation

actor Coordinator {

    private let sessionService: SessionService
    private let connectionService: ConnectionService
    private let chatService: ChatService
    private let heartbeatService: HeartbeatService
    private let logger: PolyLogger
    private let networkMonitor: NetworkMonitor
    private let lifecycleObserver: AppLifecycleObserver

    nonisolated let events = Multicaster<MessagingEvent>()
    nonisolated let connectionStatus = Multicaster<ConnectionStatus>(replayLastValue: true)

    private var observationTasks: [Task<Void, Never>] = []
    private var started = false
    private var currentSessionId: String?

    init(
        sessionService: SessionService,
        connectionService: ConnectionService,
        chatService: ChatService,
        heartbeatService: HeartbeatService,
        logger: PolyLogger,
        networkMonitor: NetworkMonitor = NetworkMonitor(),
        lifecycleObserver: AppLifecycleObserver = AppLifecycleObserver()
    ) {
        self.sessionService = sessionService
        self.connectionService = connectionService
        self.chatService = chatService
        self.heartbeatService = heartbeatService
        self.logger = logger
        self.networkMonitor = networkMonitor
        self.lifecycleObserver = lifecycleObserver
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !started else { return }
        started = true
        idleTimeoutHandled = false

        // Start NetworkMonitor + lifecycle + observation tasks BEFORE the
        // first REST call. If we're offline at launch, `sessionService.resume()`
        // will throw — but NetworkMonitor must already be listening so that
        // when the device later comes back online, `networkRestored` fires
        // and `handleNetworkRestored` can retry the resume-or-create flow.
        // Without this, an offline-at-launch consumer would be stranded on
        // the error screen with no auto-recovery path.
        networkMonitor.start()
        lifecycleObserver.start()
        startObservation()

        // Prefer resume() over createSession() so a session persisted in a
        // prior app launch survives cold start (web parity). resume() falls
        // through to createSession() on miss / expired-stored-session.
        try await sessionService.resume()

        guard let sessionId = await sessionService.state.sessionId else {
            throw PolyError.session(.sessionCreationFailed(.unknown))
        }

        // Tell ChatService whether this was a resume or a fresh start so it
        // doesn't re-emit RequestPolyAgentJoin on a session the server
        // already has joined. Mirrors web `chat.resetChat(isResume)`.
        let isResume = !(await sessionService.wasSessionCreatedThisPageLoad)
        await chatService.resetChat(isResume: isResume)
        await chatService.setRetrySender { [connectionService] outgoing in
            await connectionService.send(outgoing)
        }

        let accessToken = try await sessionService.ensureAccessToken()
        currentSessionId = sessionId

        await connectionService.connectToSession(sessionId: sessionId, accessToken: accessToken)
    }

    func send(_ text: String) async throws {
        guard let prepared = await chatService.prepareUserMessage(text: text) else {
            return
        }
        await sessionService.touch()
        await connectionService.send(prepared.outgoing)
    }

    // MARK: - Typing

    /// Throttled STARTED frames (one per `typingThrottleSeconds`) plus an
    /// auto-STOPPED frame after `typingStoppedAfterSeconds` of no further
    /// `sendTyping()` calls. Mirrors webchat's 3-second throttle but adds the
    /// STOPPED tail the backend's Nice/Salesforce adapters care about.
    private static let typingThrottleSeconds: TimeInterval = 3
    private static let typingStoppedAfterSeconds: TimeInterval = 5
    private var lastTypingStartedSent: Date?
    private var typingStoppedTask: Task<Void, Never>?

    func sendTyping() async {
        guard case .open = state else { return }

        let now = Date()
        let shouldSendStarted: Bool = {
            guard let last = lastTypingStartedSent else { return true }
            return now.timeIntervalSince(last) >= Self.typingThrottleSeconds
        }()
        if shouldSendStarted {
            lastTypingStartedSent = now
            await connectionService.send(.userTyping(TypingState.started))
        }

        // Reschedule the auto-stopped tail on every call so the STOPPED frame
        // only fires once the user actually pauses.
        typingStoppedTask?.cancel()
        typingStoppedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.typingStoppedAfterSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.emitTypingStopped()
        }
    }

    private func emitTypingStopped() async {
        lastTypingStartedSent = nil
        guard case .open = state else { return }
        await connectionService.send(.userTyping(TypingState.stopped))
    }

    /// End the active chat. The optional `reason` is forwarded to the server
    /// via `UserEndConversation` semantics and emitted on `MessagingEvent.sessionEnd`
    /// so consumers can distinguish user-initiated, host-initiated, and
    /// timeout-initiated ends.
    func end(reason: String? = "user_ended") async {
        let isOpen: Bool = {
            if case .open = state { return true }
            return false
        }()

        if isOpen {
            await connectionService.send(.userEndConversation)
            await connectionService.disconnect(code: 1000, reason: "User ended session")
        } else {
            // WS already closed — web sets a session error instead of
            // silently dropping. Surface a `disconnected` so consumers can
            // show "couldn't end chat" UX.
            logger.warn("end() called while WS not open — surfacing error", metadata: nil)
            events.emit(.disconnected(.session(.sessionEnded(reason: "Connection closed abnormally"))))
        }

        await sessionService.endSession()
        await chatService.setChatEnded(true)
        events.emit(.sessionEnd(
            Envelope(id: "", sequence: nil, timestamp: Date()),
            SessionEndPayload(reason: reason)
        ))
    }

    private var state: ConnectionStatus = .idle

    /// Consumer-driven "Start New Chat". Ends the live session server-side
    /// if open, then drives a refetch that clears the persisted session,
    /// creates a fresh one (new sessionId + new accessToken), and reconnects.
    /// Mirrors web's `chatService.startNewChat()`. Only valid after `start()`
    /// has already run — the pre-start case is handled by clearing
    /// `SessionStore` before `start()`, not by calling this method.
    func startNewSession() async {
        logger.info("Starting new session — refetching", metadata: nil)

        let isOpen: Bool = {
            if case .open = state { return true }
            return false
        }()
        if isOpen {
            await connectionService.send(.userEndConversation)
        }

        await chatService.resetChat(isResume: false)
        await sessionService.handleNewChatStarted()
        // refetchSession(manual: true) bypasses the auto-retry cap, clears
        // the store, and runs createSession via the debounce path.
        await sessionService.refetchSession(manual: true)

        let newState = await sessionService.state
        guard let newSessionId = newState.sessionId, newState.status == .active else {
            logger.error("Failed to create fresh session", metadata: nil)
            events.emit(.disconnected(.session(.sessionCreationFailed(.unknown))))
            return
        }
        currentSessionId = newSessionId

        do {
            let token = try await sessionService.ensureAccessToken()
            await connectionService.connectToSession(sessionId: newSessionId, accessToken: token)
        } catch {
            logger.error("Failed to connect to fresh session", metadata: nil)
            events.emit(.disconnected(.auth(.tokenAcquisitionFailed)))
        }
    }

    func destroy() async {
        for task in observationTasks {
            task.cancel()
        }
        observationTasks.removeAll()
        typingStoppedTask?.cancel()
        typingStoppedTask = nil
        networkMonitor.stop()
        lifecycleObserver.stop()
        await heartbeatService.destroy()
        await connectionService.destroy()
        // ChatService holds a typing timer + a stale-sweep timer that would
        // otherwise survive past `shutdown()` and keep the actor referenced.
        // Cancelling them here ensures the actor graph can be torn down on
        // app exit / token rotation without leaking background Tasks.
        await chatService.destroy()
        await sessionService.destroy()
        events.finish()
        connectionStatus.finish()
    }

    // MARK: - Observation wiring

    private func startObservation() {
        observeConnectionStatus()
        observeConnectionOpen()
        observeConnectionClose()
        observeMessages()
        observeInvalidSession()
        observeHeartbeatTick()
        observeChatEvents()
        observeNetworkChanges()
        observeNetworkLost()
        observeLifecycle()
        Task { await self.wireRefetchFailedBridge() }
    }

    private func observeConnectionStatus() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await status in connectionService.statusChanges.subscribe() {
                await self.handleStatusChange(status)
            }
        }
        observationTasks.append(task)
    }

    /// Single actor hop per status transition: records local state, fans
    /// out on the public `connectionStatus` stream, and mirrors selected
    /// transitions into the MessagingEvent stream so `events` consumers
    /// (e.g. ChatSession) see the same Ably-style transitions.
    ///
    /// MessagingEvent bridging:
    /// - `.reconnecting(attempt:)` → emit `.reconnecting(attempt:)` so the
    ///   chat UI can render "Reconnecting (1/10)..." without scraping the
    ///   lower-level status stream.
    /// - `.closed` → emit `.disconnected(nil)`. Only fires for code 1000 now
    ///   (transient closes are suppressed at the ConnectionService level),
    ///   so this represents a clean server-side end.
    /// - `.failed` is intentionally NOT mirrored — ChatSession's dedicated
    ///   connectionStatus subscriber drives `.connection = .failed(reason:)`
    ///   directly, avoiding a flash through `.disconnected`.
    private func handleStatusChange(_ status: ConnectionStatus) {
        state = status
        connectionStatus.emit(status)
        switch status {
        case .reconnecting(let attempt):
            events.emit(.reconnecting(attempt: attempt))
        case .closed:
            events.emit(.disconnected(nil))
        case .open, .connecting, .closing, .idle, .failed:
            break
        }
    }

    private func observeConnectionOpen() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in connectionService.openEvents.subscribe() {
                await self.handleConnectionOpen()
            }
        }
        observationTasks.append(task)
    }

    private func observeConnectionClose() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await event in connectionService.closeEvents.subscribe() {
                await self.handleConnectionClose(event)
            }
        }
        observationTasks.append(task)
    }

    private func observeMessages() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await event in connectionService.messageEvents.subscribe() {
                await self.handleIncomingMessage(event)
            }
        }
        observationTasks.append(task)

        let batchTask = Task { [weak self] in
            guard let self else { return }
            for await batch in connectionService.batchEvents.subscribe() {
                await self.handleIncomingBatch(batch)
            }
        }
        observationTasks.append(batchTask)
    }

    private func observeInvalidSession() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in connectionService.invalidSession.subscribe() {
                await self.handleInvalidSession()
            }
        }
        observationTasks.append(task)
    }

    private func observeHeartbeatTick() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in heartbeatService.tick.subscribe() {
                await self.handleHeartbeatTick()
            }
        }
        observationTasks.append(task)
    }

    private func observeChatEvents() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await event in chatService.eventStream.subscribe() {
                self.events.emit(event)
            }
        }
        observationTasks.append(task)
    }

    // MARK: - Handlers

    private func handleConnectionOpen() async {
        await sessionService.onSocketOpen()
        await heartbeatService.start()
        events.emit(.connected)
        logger.info("Connection opened — session ready", metadata: nil)
    }

    private func handleConnectionClose(_ event: ConnectionCloseEvent) async {
        await heartbeatService.stop()
        await sessionService.onSocketClose(event: event)

        // Clean close (1000): server ended the conversation. Server may close the
        // WebSocket directly without sending SESSION_END first. onCleanClose()
        // is idempotent: if SESSION_END was already processed, chatEnded is
        // already true and this is a no-op.
        // Guard: skip if a new connection is already underway (startNewSession
        // disconnects the old socket with 1000, and the late close event can
        // race the new session's resetChat, re-latching chatEnded).
        if event.code == 1000 {
            switch state {
            case .connecting, .open:
                break
            default:
                await chatService.onCleanClose()
            }
        }

        // MessagingEvent.disconnected emission lives in bridgeStatusToEvent
        // (driven by the .closed status, which now fires only for 1000).
        // Transient closes that lead to scheduleReconnect emit .reconnecting
        // instead, giving consumers a clean open → reconnecting transition.
    }

    private func handleIncomingBatch(_ events: [MessagingEvent]) async {
        for event in events {
            if let seq = event.envelope?.sequence {
                await connectionService.updateLastSequence(seq)
            }
            if case .sessionStart(_, let payload) = event {
                await applySessionCapabilities(payload.capabilities)
            }
            if case .sessionEnd = event {
                await sessionService.endSession()
            }
            switch event {
            case .agentMessage, .agentMessageChunk, .liveAgentMessage, .userMessage:
                await sessionService.touch()
            default: break
            }
        }
        await sessionService.clearError()

        let sideEffects = await chatService.handleBatch(events)
        for effect in sideEffects {
            await connectionService.send(effect)
        }
    }

    private func handleIncomingMessage(_ event: MessagingEvent) async {
        if let seq = event.envelope?.sequence {
            await connectionService.updateLastSequence(seq)
        }

        if case .sessionStart(_, let payload) = event {
            // Apply capabilities INLINE before the message is handed to
            // ChatService. Previously this spawned un-awaited Tasks, which
            // raced subsequent messages — heartbeat interval and
            // maxReconnectAttempts could apply LATER than the next message
            // referenced them.
            await applySessionCapabilities(payload.capabilities)
        }

        // Server-driven SESSION_END is terminal — the session is dead on the
        // server. Clear the persisted session so `hasResumableSession()` returns
        // false and the next consumer-side launch lands on the "Start New Chat"
        // path instead of trying to resume a session the server has already
        // discarded. Idempotent vs. user-initiated end() which already cleared.
        if case .sessionEnd = event {
            await sessionService.endSession()
        }

        // Touch on real message activity (not on heartbeat ticks) so
        // idle-timeout can actually fire. Bots and live agents talking
        // both count as activity that should keep the session alive.
        switch event {
        case .agentMessage, .agentMessageChunk, .liveAgentMessage, .userMessage:
            await sessionService.touch()
        default:
            break
        }

        // A valid incoming message proves the connection is healthy; clear
        // any latched session error (e.g. the "Connection closed abnormally"
        // banner from a brief 1006 drop that auto-recovered). Heartbeats are
        // transport-level keep-alives, not real server activity.
        if case .heartbeat = event {
            // skip
        } else {
            await sessionService.clearError()
        }

        let sideEffects = await chatService.handleMessage(event)
        for effect in sideEffects {
            await connectionService.send(effect)
        }
    }

    private func handleInvalidSession() async {
        logger.warn("Invalid session — refetching", metadata: nil)
        // refetchSession() forces a fresh session creation; from chat's
        // perspective this is a brand-new conversation (isResume=false) and a
        // RequestPolyAgentJoin should be sent when the new SESSION_START arrives.
        await chatService.resetChat(isResume: false)
        await sessionService.handleNewChatStarted()
        await sessionService.refetchSession()

        let newState = await sessionService.state
        if let newSessionId = newState.sessionId, newState.status == .active {
            currentSessionId = newSessionId
            do {
                let token = try await sessionService.ensureAccessToken()
                await connectionService.connectToSession(sessionId: newSessionId, accessToken: token)
            } catch {
                logger.error("Failed to reconnect after refetch", metadata: nil)
                events.emit(.disconnected(.auth(.tokenAcquisitionFailed)))
            }
        } else {
            // Refetch failed — roll back the invalid-session budget
            await connectionService.notifyRefetchFailed()
        }
    }

    /// Wires SessionService.onRefetchFailed to ConnectionService's
    /// invalid-session budget rollback. Called from startObservation.
    private func wireRefetchFailedBridge() async {
        await sessionService.onRefetchFailed { [weak self] in
            guard let self else { return }
            Task { await self.connectionService.notifyRefetchFailed() }
        }
    }

    private static let maxConnectionDurationSeconds: TimeInterval = 7200

    private func handleHeartbeatTick() async {
        // Per-tick error isolation: heartbeat send and timeout check are
        // independent — one failing must not block the other.
        //
        // Only send when the socket is genuinely open; queuing heartbeats
        // against a connecting/reconnecting/closing socket is wasted work
        // and (on some transports) leaks into the wrong session.
        if case .open = await connectionService.currentStatus() {
            await connectionService.send(.heartbeat)
        }

        if await sessionService.checkTimeout() && !idleTimeoutHandled {
            await handleIdleTimeout(reason: "heartbeat")
            return
        }

        if let startedAt = await connectionService.connectionStartedAt,
           Date().timeIntervalSince(startedAt) > Self.maxConnectionDurationSeconds {
            await handleConnectionDurationExceeded()
        }
    }

    private func handleConnectionDurationExceeded() async {
        logger.info("Connection duration limit reached — reconnecting", metadata: nil)
        await connectionService.dropConnectionForReconnect(reason: "Connection duration limit")
    }

    /// Atomic teardown when an idle timeout is detected. Called from both the
    /// heartbeat tick and foreground-return paths so the two routes stay in
    /// lockstep: cancel reconnect, reset chat, end session as expired, notify.
    private func handleIdleTimeout(reason: String) async {
        idleTimeoutHandled = true
        logger.info("Session timeout detected", metadata: ["via": reason])
        await connectionService.cancelReconnect()
        await chatService.resetChat(isResume: false)
        await sessionService.endSession(reason: .expired)
        events.emit(.disconnected(.session(.sessionExpired)))
    }

    // Flag prevents re-fire of the idle-timeout teardown on subsequent
    // heartbeats once we've already detected expiry. Reset on next start().
    private var idleTimeoutHandled: Bool = false

    // MARK: - Network & Lifecycle

    private func observeNetworkChanges() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in networkMonitor.networkRestored.subscribe() {
                await self.handleNetworkRestored()
            }
        }
        observationTasks.append(task)
    }

    private func observeNetworkLost() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in networkMonitor.networkLost.subscribe() {
                await self.handleNetworkLost()
            }
        }
        observationTasks.append(task)
    }

    private func observeLifecycle() {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in lifecycleObserver.foreground.subscribe() {
                await self.handleForeground()
            }
        }
        observationTasks.append(task)
    }

    private func handleNetworkRestored() async {
        logger.info("Network restored", metadata: nil)
        await connectionService.resetReconnectBudget()
        let sessionState = await sessionService.state

        // Path 1 — we have an active server-side session; just rebuild the WS.
        if sessionState.status == .active, let sid = currentSessionId {
            do {
                let token = try await sessionService.ensureAccessToken()
                await connectionService.connectToSession(sessionId: sid, accessToken: token)
            } catch {
                logger.error("Failed to reconnect after network restore", metadata: nil)
            }
            return
        }

        // Path 2 — session never created (offline at launch, REST call failed)
        // or its state was wiped. Retry the resume-or-create flow now that
        // the network is back. Without this, the SDK would sit on the error
        // state forever even after connectivity returned.
        if sessionState.sessionId == nil {
            logger.info("Network restored — retrying session creation", metadata: nil)
            do {
                try await sessionService.resume()
                guard let newSid = await sessionService.state.sessionId else {
                    logger.error("Resume succeeded but no sessionId", metadata: nil)
                    return
                }
                let isResume = !(await sessionService.wasSessionCreatedThisPageLoad)
                await chatService.resetChat(isResume: isResume)
                currentSessionId = newSid
                let token = try await sessionService.ensureAccessToken()
                await connectionService.connectToSession(sessionId: newSid, accessToken: token)
            } catch {
                logger.error("Retry session creation failed after network restore", metadata: nil)
            }
        }
    }

    /// OS detected the device went offline. If we have an open socket, drop
    /// it now so consumers see `.reconnecting` immediately rather than after
    /// the WS keep-alive times out (1-30s). Gated on `state == .open` so a
    /// drop mid-handshake doesn't trigger `routeToInvalidSession` and an
    /// unnecessary session refetch — the natural flow will handle that.
    private func handleNetworkLost() async {
        guard currentSessionId != nil else { return }
        if case .open = state {
            logger.info("Network lost — dropping socket", metadata: nil)
            await connectionService.dropConnectionForReconnect(reason: "Network lost")
        }
    }

    private func handleForeground() async {
        await sessionService.touch()

        if await sessionService.checkTimeout() && !idleTimeoutHandled {
            await handleIdleTimeout(reason: "foreground")
            return
        }

        let sessionState = await sessionService.state
        let needsReconnect = sessionState.status == .active && !sessionState.isReady
        guard needsReconnect, let sid = currentSessionId else { return }

        do {
            let token = try await sessionService.ensureAccessToken()
            await connectionService.connectToSession(sessionId: sid, accessToken: token)
        } catch {
            logger.error("Failed to reconnect on foreground", metadata: nil)
        }
    }

    // MARK: - Capabilities

    private func applySessionCapabilities(_ capabilities: SessionCapabilities) async {
        // heartbeatIntervalSeconds:
        //   0         → server says no heartbeat needed; stop the running heartbeat.
        //   >0        → update heartbeat to the server's preferred interval.
        //   undefined → reset to the default interval so a prior session's custom
        //               value doesn't leak into this session.
        //
        // Awaited inline (not Task-spawned) so capabilities are guaranteed to
        // be in effect before the next incoming message is handled.
        if let interval = capabilities.heartbeatIntervalSeconds {
            if interval == 0 {
                await heartbeatService.stop()
            } else if interval > 0 {
                await heartbeatService.setInterval(interval)
            } else {
                await heartbeatService.resetToDefaultInterval()
            }
        } else {
            await heartbeatService.resetToDefaultInterval()
        }

        if let maxAttempts = capabilities.maxReconnectAttempts {
            await connectionService.setMaxReconnectAttempts(maxAttempts)
        }
    }
}
