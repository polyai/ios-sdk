// Copyright PolyAI Limited

import Foundation

final class WebSocketTransport: @unchecked Sendable, Connection {

    private let logger: PolyLogger
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var delegate: WebSocketSessionDelegate?
    private var receiveTask: Task<Void, Never>?

    private let openCaster = Multicaster<Void>()
    private let closeCaster = Multicaster<ConnectionCloseEvent>()
    private let messageCaster = Multicaster<MessagingEvent>()
    private let batchCaster = Multicaster<[MessagingEvent]>()
    private let rawFrameCaster = Multicaster<Data>()
    private let errorCaster = Multicaster<PolyError>()

    private let lock = NSLock()
    private var _status: ConnectionStatus = .idle
    // `closeEmittedThisAttempt` guards against duplicate `closeCaster.emit` when
    // both the synthetic close (from disconnect/replace) and the late delegate
    // didCloseWith callback fire for the same socket. First emitter wins; the
    // flag is reset on each `connect()` so a fresh attempt can emit one close.
    private var _closeEmittedThisAttempt: Bool = false

    init(logger: PolyLogger) {
        self.logger = logger
    }

    // MARK: - Close-emit gate

    /// Returns true exactly once per connection attempt; false if a prior
    /// caller already emitted the close for this attempt.
    @discardableResult
    private func claimCloseEmit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _closeEmittedThisAttempt { return false }
        _closeEmittedThisAttempt = true
        return true
    }

    private func resetCloseEmit() {
        lock.lock()
        _closeEmittedThisAttempt = false
        lock.unlock()
    }

    // MARK: - Connection protocol

    var status: ConnectionStatus {
        get async {
            lock.lock()
            defer { lock.unlock() }
            return _status
        }
    }

    var openEvents: AsyncStream<Void> { openCaster.subscribe() }
    var closeEvents: AsyncStream<ConnectionCloseEvent> { closeCaster.subscribe() }
    var messages: AsyncStream<MessagingEvent> { messageCaster.subscribe() }
    var batchEvents: AsyncStream<[MessagingEvent]> { batchCaster.subscribe() }
    var rawFrames: AsyncStream<Data> { rawFrameCaster.subscribe() }
    var errors: AsyncStream<PolyError> { errorCaster.subscribe() }

    func connect(url: URL) async {
        // Replace-on-connect: if a socket is already in flight, synthesise a
        // close event with code 4000 ("Replacing connection") BEFORE tearing
        // it down. ConnectionService recognises 4000 as a clean replace and
        // does NOT engage reconnect — unlike code 1000 (server-initiated
        // close), which would terminate the reconnect state machine. Without
        // this, calling connect() twice (e.g. on network restore while the
        // stale socket is still open) causes the SDK to stop reconnecting.
        //
        // TODO(backend-confirm Q3): verify AWS API Gateway and the backend
        // tolerate close code 4000 untouched. See _ios-gap-report/BACKEND-QUESTIONS.md.
        if let staleTask = task {
            if claimCloseEmit() {
                let event = ConnectionCloseEvent(
                    code: 4000,
                    reason: "Replacing connection",
                    wasClean: true
                )
                logger.debug("Replacing existing socket", metadata: ["code": "4000"])
                closeCaster.emit(event)
            }
            // Send a real WS close frame on the wire before tearing down the
            // session, so the server gets a clean close handshake (code 1001
            // "going away") rather than the TCP-level abort that
            // `invalidateAndCancel` produces. Without this, some backends
            // leave the prior session in a half-cleaned state, which can
            // stall the next session's agent provisioning (observed
            // empirically on rapid start-new-session sequences when the
            // outgoing session had a conversation history). Brief sleep
            // lets the frame transmit before we invalidate the URLSession.
            staleTask.cancel(with: .goingAway, reason: nil)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        cleanupCurrentConnection()
        resetCloseEmit()

        setStatus(.connecting)
        logger.debug("Connecting to \(url.host ?? "unknown")", metadata: nil)

        let del = WebSocketSessionDelegate(
            onOpen: { [weak self] in self?.handleOpen() },
            onClose: { [weak self] code, reason in self?.handleClose(code: code, reason: reason) },
            onTaskCompleted: { [weak self] error in self?.handleTaskCompleted(error: error) }
        )
        self.delegate = del

        let session = URLSession(configuration: .default, delegate: del, delegateQueue: nil)
        self.urlSession = session

        let wsTask = session.webSocketTask(with: url)
        self.task = wsTask
        wsTask.resume()

        startReceiveLoop()
    }

    func disconnect(code: Int = 1000, reason: String = "") async {
        setStatus(.closing)
        logger.debug("Disconnecting", metadata: ["code": String(code)])

        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))

        // Emit close synchronously. URLSession.invalidateAndCancel (in
        // cleanupCurrentConnection) releases the delegate, so the
        // didCloseWith callback may never fire — without this synthesis,
        // downstream observers (Coordinator.handleConnectionClose,
        // HeartbeatService teardown) miss user-initiated disconnects.
        let event = ConnectionCloseEvent(
            code: code,
            reason: reason,
            wasClean: code == 1000
        )
        if claimCloseEmit() {
            setStatus(.closed(event))
            closeCaster.emit(event)
        }
        cleanupCurrentConnection()
    }

    func send(_ event: OutgoingEvent) async {
        guard let data = WireEncoder.encode(event) else { return }
        let wireType = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String
        logger.info("WS frame sending", metadata: ["type": wireType ?? "(unparsable)"])
        // `send(_:)` is fire-and-forget — if the socket is mid-reconnect,
        // ChatService's retry ladder owns recovery for user messages and
        // the heartbeat/typing frames are safely droppable. Surface the
        // `.notConnected` throw via the error stream so observers still
        // get visibility, but don't propagate to legacy callers that
        // expect a non-throwing API.
        do {
            try await sendRaw(data)
        } catch let error as PolyError {
            errorCaster.emit(error)
        } catch {
            errorCaster.emit(.transport(.networkError(error.localizedDescription)))
        }
    }

    func sendRaw(_ data: Data) async throws {
        guard let t = task else {
            // Surfacing this as a throw (rather than silent return) lets
            // ChatService's retry ladder back off and wait for the next
            // `.open` instead of treating the send as accepted.
            logger.warn("Send dropped — no active task", metadata: nil)
            throw PolyError.transport(.notConnected)
        }
        let currentStatus = await status
        if case .closed = currentStatus {
            logger.warn("Send dropped — socket closed", metadata: nil)
            throw PolyError.transport(.notConnected)
        }

        guard let string = String(data: data, encoding: .utf8) else {
            errorCaster.emit(.transport(.protocolError(reason: "Cannot encode data as UTF-8")))
            throw PolyError.transport(.protocolError(reason: "Cannot encode data as UTF-8"))
        }

        do {
            try await t.send(.string(string))
        } catch {
            logger.warn("Send failed", metadata: ["error": error.localizedDescription])
            errorCaster.emit(.transport(.networkError(error.localizedDescription)))
            throw PolyError.transport(.networkError(error.localizedDescription))
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        logger.debug("Starting receive loop", metadata: nil)
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let t = self.task else { break }
                do {
                    let message = try await t.receive()
                    self.handleFrame(message)
                } catch {
                    if !Task.isCancelled {
                        self.logger.debug("Receive loop ended", metadata: ["error": error.localizedDescription])
                    }
                    break
                }
            }
        }
    }

    func handleFrame(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            // Cheap parse just for the `type` field so we get visibility into
            // every server frame at info level. Falls back to a generic log if
            // the frame isn't JSON.
            let wireType = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String
            logger.info("WS frame received", metadata: ["type": wireType ?? "(unparsable)"])
            rawFrameCaster.emit(data)

            let events = WireDecoder.decode(data, logger: logger)
            if events.count > 1 {
                batchCaster.emit(events)
            } else {
                for event in events {
                    messageCaster.emit(event)
                }
            }

        case .data:
            logger.warn("Binary frame received — text frames only", metadata: nil)
            errorCaster.emit(.transport(.protocolError(reason: "Binary frames not supported")))

        @unknown default:
            break
        }
    }

    // MARK: - Delegate callbacks

    private func handleOpen() {
        setStatus(.open)
        logger.info("WebSocket opened", metadata: nil)
        openCaster.emit(())
    }

    private func handleClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // If `disconnect()` or `connect()` (replace path) already synthesised
        // the close for this attempt, drop this late delegate callback —
        // emitting again would cause duplicate `.disconnected` events
        // downstream.
        guard claimCloseEmit() else {
            receiveTask?.cancel()
            receiveTask = nil
            return
        }

        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let event = ConnectionCloseEvent(
            code: code.rawValue,
            reason: reasonString,
            wasClean: code == .normalClosure
        )
        setStatus(.closed(event))
        logger.info("WebSocket closed", metadata: ["code": String(code.rawValue), "reason": reasonString])
        closeCaster.emit(event)

        receiveTask?.cancel()
        receiveTask = nil
    }

    /// Synthesise a close when the underlying URLSession task ends with an
    /// error. Covers handshake-time failures (DNS, TLS, HTTP non-101 response
    /// to the upgrade — e.g. when the server rejects a stale resumed
    /// `session_id`) which never trigger `didCloseWith` because the socket
    /// never opened. Without this, the receive loop catches the error,
    /// breaks silently, and `ConnectionService` never engages its
    /// reconnect / invalid-session ladder.
    ///
    /// For post-handshake drops, `didCloseWith` fires first and
    /// `claimCloseEmit()` gates this path off — no double emission.
    private func handleTaskCompleted(error: Error) {
        let nsError = error as NSError

        // Filter out cancellations we initiated ourselves. `invalidateAndCancel()`
        // in `cleanupCurrentConnection()` (replace-on-connect, disconnect()) puts
        // the old task into NSURLErrorCancelled. The corresponding delegate
        // callback may arrive AFTER `resetCloseEmit()` has cleared the gate for
        // the new attempt — treating it as a real failure synthesises a 1006
        // close on the new attempt, which `ConnectionService` then misreads as
        // a handshake failure and routes to invalid-session refetch.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            receiveTask?.cancel()
            receiveTask = nil
            return
        }

        guard claimCloseEmit() else {
            receiveTask?.cancel()
            receiveTask = nil
            return
        }

        // Pick the close code based on the failure class:
        //
        // - Network-unavailable errors (offline, DNS, host unreachable, etc.)
        //   are TRANSIENT — the session_id is fine; the device just can't
        //   reach the server right now. Emit code 4003 so ConnectionService's
        //   reconnect ladder engages without spending the invalid-session
        //   budget or routing to refetch. Otherwise every offline reconnect
        //   attempt would burn a budget slot, refetchSession() would fail
        //   (also offline) and corrupt SessionState, and when the network
        //   came back the SDK could no longer auto-recover (handleNetworkRestored
        //   bails on non-active session state).
        //
        // - Anything else (typically -1011 BadServerResponse on a handshake
        //   reject, TLS errors, etc.) is a genuine session-level failure.
        //   Emit code 1006 — the existing handshake-failure routing handles
        //   it correctly.
        let isTransientNetwork = nsError.domain == NSURLErrorDomain
            && Self.transientNetworkErrorCodes.contains(nsError.code)
        let code = isTransientNetwork ? 4003 : 1006

        let description = nsError.localizedDescription
        let event = ConnectionCloseEvent(
            code: code,
            reason: "Task failed: \(description)",
            wasClean: false
        )
        setStatus(.closed(event))
        logger.info("WebSocket task failed", metadata: [
            "code": String(code),
            "error": description,
        ])
        closeCaster.emit(event)

        receiveTask?.cancel()
        receiveTask = nil
    }

    /// NSURLError codes that mean "device can't reach the network right now"
    /// — none of which imply the server-side session is invalid.
    private static let transientNetworkErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
    ]

    // MARK: - Internal

    private func setStatus(_ status: ConnectionStatus) {
        lock.lock()
        _status = status
        lock.unlock()
    }

    private func cleanupCurrentConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        // Don't `task?.cancel(with: .normalClosure)` here — invalidateAndCancel
        // tears down the task, and an explicit cancel would risk queuing a
        // delegate didCloseWith(code:1000) that races with our synthesised
        // close. claimCloseEmit() would drop it, but it's cleaner not to
        // generate it in the first place.
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        delegate = nil
    }
}

// MARK: - URLSession WebSocket Delegate

private final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let onOpen: @Sendable () -> Void
    let onClose: @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void
    let onTaskCompleted: @Sendable (Error) -> Void

    init(
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void,
        onTaskCompleted: @escaping @Sendable (Error) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onTaskCompleted = onTaskCompleted
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose(closeCode, reason)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Successful task completion (clean close) reports nil — no work.
        // Errors here cover handshake-time failures (DNS, TLS, HTTP non-101)
        // which never fire `didCloseWith`.
        guard let error else { return }
        onTaskCompleted(error)
    }

    // FUTURE: cert pinning would intercept didReceive:challenge here. See
    // CertificatePinner.swift (disabled) for the helper implementation.
}
