// Copyright PolyAI Limited

import Foundation

actor SessionService {

    private(set) var state: SessionState
    private let api: any RestApiPort
    private let config: Configuration
    private let logger: PolyLogger
    private let store: SessionStore

    private var accessToken: String?
    private var tokenExpiresAt: Date?
    private var lastActivityTimestamp: Date = Date()
    private var refetchAttempts: Int = 0
    private var errorDelayTask: Task<Void, Never>?
    // Debounce: pending refetch task + waiters that should resolve when the
    // debounced refetch completes. Mirrors web `REFETCH_DEBOUNCE_MS=300` +
    // resolver queue pattern.
    private var pendingRefetchTask: Task<Void, Never>?
    private var refetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingManualRefetch: Bool = false
    private var onRefetchFailedListeners: [@Sendable () -> Void] = []
    /// True when the *current* sessionId was created in this process (vs.
    /// resumed from persisted storage). Mirrors web `SessionService`:
    /// drives `isResume` plumbing so we don't re-request `RequestPolyAgentJoin`
    /// on a session the server already considers "in flight".
    private(set) var wasSessionCreatedThisPageLoad: Bool = false

    // State-like stream: replay the current SessionState to late subscribers.
    nonisolated let stateChanges = Multicaster<SessionState>(replayLastValue: true)

    /// Idle window after which a session is considered expired. Injectable so
    /// tests can drive idle/expiry deterministically; production default 600s
    /// (matches the backend's WebSocket idle timeout — sessions older than
    /// this have been killed server-side, so attempting to resume 404s).
    private let sessionTimeoutSeconds: TimeInterval
    private static let maxRefetchAttempts = 3
    private static let refetchDebounceNanos: UInt64 = 300_000_000

    init(api: any RestApiPort, config: Configuration, logger: PolyLogger, sessionTimeoutSeconds: TimeInterval = 600) {
        self.api = api
        self.config = config
        self.logger = logger
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.store = SessionStore(apiKey: config.apiKey)
        self.state = SessionState(
            sessionId: nil, status: .unknown,
            isReady: false, isLoading: false,
            error: nil
        )
    }

    // MARK: - Session lifecycle

    private static let connectorValidationErrors: Set<SessionErrorCode> = [
        .errorParsingRequest, .missingAuthHeaders,
        .connectorLookupFailed, .connectorValidationFailed,
    ]

    func createSession() async throws {
        guard !state.isLoading else { return }

        // Reset token before each createSession so the full two-step auth
        // flow is always performed from scratch (prevents stale token reuse)
        accessToken = nil

        updateState(SessionState(
            sessionId: state.sessionId, status: state.status,
            isReady: false, isLoading: true, error: nil
        ))

        do {
            let tokenResponse = try await api.obtainAccessToken()
            accessToken = tokenResponse.accessToken
            tokenExpiresAt = tokenResponse.tokenExpiresAt

            let context = SessionContext(
                platform: Platform.ios.rawValue,
                streamingEnabled: config.streamingEnabled
            )
            let session = try await api.createSession(context: context)

            lastActivityTimestamp = Date()
            // Persist the (sessionId, accessToken) pair atomically so a
            // cross-launch resume reconnects as the SAME user identity.
            // Each `/access-token` call mints a fresh user; storing the
            // token alongside the session is how we avoid creating a new
            // user on restart and then failing to attach to the old session.
            store.save(
                sessionId: session.sessionId,
                accessToken: tokenResponse.accessToken,
                timestamp: lastActivityTimestamp,
                tokenExpiresAt: tokenExpiresAt
            )
            wasSessionCreatedThisPageLoad = true

            updateState(SessionState(
                sessionId: session.sessionId, status: .active,
                isReady: false, isLoading: false, error: nil
            ))

            logger.info("Session created", metadata: ["sessionId": session.sessionId])
        } catch let error as PolyError {
            let errorCode: SessionErrorCode? = switch error {
            case .auth(.unauthorized): .connectorValidationFailed
            case .session(.sessionCreationFailed(let code)): code
            default: .unknown
            }
            let isInvalidApiKey = if let code = errorCode {
                Self.connectorValidationErrors.contains(code)
            } else {
                false
            }
            updateState(SessionState(
                sessionId: nil, status: .unknown,
                isReady: false, isLoading: false, error: errorCode,
                hasInvalidApiKey: isInvalidApiKey
            ))
            throw error
        } catch {
            updateState(SessionState(
                sessionId: nil, status: .unknown,
                isReady: false, isLoading: false, error: .unknown
            ))
            throw PolyError.transport(.networkError(error.localizedDescription))
        }
    }

    func resume() async throws {
        if let stored = store.load() {
            let age = Date().timeIntervalSince(stored.timestamp)
            let withinTimeout = age < sessionTimeoutSeconds
            // Both halves must be valid for resume to work: the session row
            // must be within the idle window AND the access token must be
            // structurally valid + unexpired. If either fails we clear and
            // create fresh — restoring half a session creates a mismatched
            // user identity that the server rejects, leaving the consumer
            // stuck on "connecting".
            if withinTimeout,
               let token = stored.accessToken,
               JWTValidator.isStructurallyValid(token) {
                lastActivityTimestamp = stored.timestamp
                accessToken = token
                tokenExpiresAt = stored.tokenExpiresAt
                wasSessionCreatedThisPageLoad = false
                // Briefly surface .restored so consumers can show stored
                // transcript / "Welcome back" UI before the WS handshake
                // promotes the state back to .active.
                updateState(SessionState(
                    sessionId: stored.sessionId, status: .restored,
                    isReady: false, isLoading: false, error: nil
                ))
                updateState(SessionState(
                    sessionId: stored.sessionId, status: .active,
                    isReady: false, isLoading: false, error: nil
                ))
                logger.info("Session resumed", metadata: ["sessionId": stored.sessionId])
                return
            } else {
                if !withinTimeout {
                    logger.info("Stored session past idle timeout — starting fresh", metadata: nil)
                } else {
                    logger.info("Stored access token missing or expired — starting fresh", metadata: nil)
                }
                store.clear()
            }
        }
        // No stored session (or stored token invalid/expired): create a fresh one.
        // createSession() sets wasSessionCreatedThisPageLoad = true.
        try await createSession()
    }

    func endSession(reason: SessionEndReason = .ended) {
        store.clear()
        wasSessionCreatedThisPageLoad = false
        let status: SessionStatus = (reason == .expired) ? .expired : .ended
        updateState(SessionState(
            sessionId: nil, status: status,
            isReady: false, isLoading: false, error: nil
        ))
        logger.info("Session ended", metadata: ["reason": reason.rawValue])
    }

    enum SessionEndReason: String {
        case ended
        case expired
    }

    // MARK: - Timeout

    /// Whether the session has been idle past `sessionTimeoutSeconds`.
    /// Reads the persisted timestamp (not the in-memory value alone) so cold
    /// launches honour activity from the previous run.
    func checkTimeout() -> Bool {
        let lastStored = store.load()?.timestamp ?? lastActivityTimestamp
        let effective = max(lastStored, lastActivityTimestamp)
        return Date().timeIntervalSince(effective) > sessionTimeoutSeconds
    }

    /// Records user/agent message activity. Per web semantics this MUST NOT
    /// be called from heartbeat ticks (which would prevent idle-timeout from
    /// ever firing) — only from real user/agent message handlers.
    func touch() {
        lastActivityTimestamp = Date()
        store.updateTimestamp(lastActivityTimestamp)
    }

    // MARK: - Refetch

    /// Re-create the session after the server has rejected it (invalid-session
    /// path). Multiple calls within `refetchDebounceNanos` (300ms) collapse
    /// into a single refetch — waiters share the result.
    ///
    /// - Parameter manual: when true (e.g. user-initiated "Start new chat"),
    ///   resets the attempt counter and bypasses the cap. Auto refetches
    ///   share the 3-attempt budget.
    func refetchSession(manual: Bool = false) async {
        if manual {
            refetchAttempts = 0
            pendingManualRefetch = true
        }

        guard refetchAttempts < Self.maxRefetchAttempts else {
            logger.warn("Max refetch attempts reached", metadata: nil)
            updateState(SessionState(
                sessionId: nil, status: .unknown,
                isReady: false, isLoading: false, error: .unknown
            ))
            notifyRefetchFailedListeners()
            return
        }

        // If a debounced refetch is already pending, queue ourselves and
        // wait for it instead of triggering a second one.
        if pendingRefetchTask != nil {
            await withCheckedContinuation { continuation in
                refetchWaiters.append(continuation)
            }
            return
        }

        await executeRefetch()
    }

    private func executeRefetch() async {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refetchDebounceNanos)
            guard let self, !Task.isCancelled else { return }
            await self.performRefetch()
        }
        pendingRefetchTask = task
        await task.value
    }

    private func performRefetch() async {
        refetchAttempts += 1
        store.clear()

        var didFail = false
        do {
            try await createSession()
        } catch {
            didFail = true
            logger.error("Refetch failed", metadata: ["attempt": String(refetchAttempts)])
        }

        if didFail {
            // Notify external budget-holders (ConnectionService's
            // invalidSessionReconnects counter) so they don't silently spend
            // a slot on a failed refetch. SessionService's OWN
            // `refetchAttempts` counter stays incremented — that's the cap
            // enforced here.
            notifyRefetchFailedListeners()
        }

        // Resolve any waiters that queued during the debounce window.
        let waiters = refetchWaiters
        refetchWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        pendingRefetchTask = nil
        pendingManualRefetch = false
    }

    /// Register a listener that fires when refetch attempts are exhausted
    /// or a refetch throws unexpectedly. Used by Coordinator to roll back
    /// ConnectionService's invalid-session budget.
    func onRefetchFailed(_ listener: @Sendable @escaping () -> Void) {
        onRefetchFailedListeners.append(listener)
    }

    private func notifyRefetchFailedListeners() {
        for listener in onRefetchFailedListeners {
            listener()
        }
    }

    // MARK: - Socket lifecycle callbacks

    func onSocketOpen() {
        errorDelayTask?.cancel()
        refetchAttempts = 0
        touch()
        updateState(SessionState(
            sessionId: state.sessionId, status: .active,
            isReady: true, isLoading: false, error: nil
        ))
    }

    /// Clear any latched session error (e.g. "Connection closed abnormally").
    /// Called by Coordinator on any valid incoming message — the fact that
    /// a message arrived proves the connection is healthy.
    func clearError() {
        guard state.error != nil else { return }
        errorDelayTask?.cancel()
        errorDelayTask = nil
        updateState(SessionState(
            sessionId: state.sessionId,
            status: state.status,
            isReady: state.isReady,
            isLoading: state.isLoading,
            error: nil,
            hasInvalidApiKey: state.hasInvalidApiKey
        ))
    }

    func onSocketClose(event: ConnectionCloseEvent) {
        updateState(SessionState(
            sessionId: state.sessionId, status: state.status,
            isReady: false, isLoading: state.isLoading, error: state.error
        ))

        if event.code == 1006 {
            errorDelayTask?.cancel()
            errorDelayTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                if self.state.error == nil && !self.state.isReady {
                    self.updateState(SessionState(
                        sessionId: self.state.sessionId, status: self.state.status,
                        isReady: false, isLoading: false,
                        error: .connectionClosedAbnormally
                    ))
                }
            }
        }
    }

    func handleNewChatStarted() {
        refetchAttempts = 0
    }

    // MARK: - Token management

    func ensureAccessToken() async throws -> String {
        if let token = accessToken,
           JWTValidator.isStructurallyValid(token),
           !isTokenExpiringSoon() {
            return token
        }

        let response = try await api.obtainAccessToken()
        guard JWTValidator.isStructurallyValid(response.accessToken) else {
            logger.error("obtainAccessToken returned malformed JWT", metadata: nil)
            throw PolyError.auth(.tokenAcquisitionFailed)
        }
        accessToken = response.accessToken
        tokenExpiresAt = response.tokenExpiresAt
        store.save(
            sessionId: state.sessionId ?? "",
            accessToken: response.accessToken,
            timestamp: lastActivityTimestamp,
            tokenExpiresAt: tokenExpiresAt
        )
        return response.accessToken
    }

    private func isTokenExpiringSoon(thresholdSeconds: TimeInterval = 300) -> Bool {
        guard let expiresAt = tokenExpiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < thresholdSeconds
    }

    // MARK: - Teardown

    /// Cancel any in-flight Tasks so the actor can be released cleanly on
    /// `PolyMessagingClient.shutdown()` / `Coordinator.destroy()`. Without
    /// this, the debounced refetch Task and the error-delay Task would
    /// linger past tear-down and keep this actor referenced.
    func destroy() {
        errorDelayTask?.cancel()
        errorDelayTask = nil
        pendingRefetchTask?.cancel()
        pendingRefetchTask = nil
        for waiter in refetchWaiters {
            waiter.resume()
        }
        refetchWaiters.removeAll()
        stateChanges.finish()
    }

    // MARK: - Private

    private func updateState(_ newState: SessionState) {
        state = newState
        stateChanges.emit(newState)
    }
}
