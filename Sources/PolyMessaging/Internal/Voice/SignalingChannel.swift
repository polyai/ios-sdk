// Copyright PolyAI Limited

import Foundation

/// Lifecycle + inbound events from the WebRTC signaling WebSocket.
enum SignalingChannelEvent: Sendable {
    case opened
    case message(Data)
    case closed(code: Int, reason: String)
    case failed(PolyError)
}

/// Abstraction over the signaling WebSocket so the call pipeline can be driven
/// against a mock in tests and the live gateway in production.
protocol SignalingChannel: Sendable {
    /// Open the socket. Lifecycle is reported through `events` (`.opened` first).
    func open() async
    /// Send a pre-encoded JSON frame. Returns whether the frame was handed to the
    /// socket — a `false` means the data was NOT sent (the caller must requeue it
    /// if it matters); the channel also reports the failure through `events`.
    @discardableResult
    func send(_ data: Data) async -> Bool
    /// Close the socket and stop emitting events.
    func close() async
    var events: AsyncStream<SignalingChannelEvent> { get }
}

/// `URLSessionWebSocketTask`-backed signaling channel for the WebRTC gateway.
final class GatewaySignalingChannel: SignalingChannel, @unchecked Sendable {

    private let url: URL
    private let logger: PolyLogger

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var delegate: SignalingSocketDelegate?
    private var receiveTask: Task<Void, Never>?

    private let caster = Multicaster<SignalingChannelEvent>()
    private let lock = NSLock()
    private var terminated = false
    // Each open() starts a new connection generation. Delegate callbacks and
    // receive-loop events carry the generation they belong to, so a delayed
    // close/open/error from a cancelled socket can never terminate — or falsely
    // open — the connection that replaced it.
    private var generation = 0

    init(url: URL, logger: PolyLogger) {
        self.url = url
        self.logger = logger
    }

    var events: AsyncStream<SignalingChannelEvent> { caster.subscribe() }

    func open() async {
        // Reset for a fresh connection so the same instance can be re-opened on
        // reconnect: bump the generation (orphaning any in-flight callbacks from
        // the old socket), clear the terminal latch, and cancel the prior socket.
        let gen: Int = withLock {
            generation += 1
            terminated = false
            return generation
        }
        receiveTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()

        logger.debug("Opening signaling WS", metadata: ["host": url.host ?? "unknown"])
        let del = SignalingSocketDelegate(
            onOpen: { [weak self] in self?.emitCurrent(gen, .opened) },
            onClose: { [weak self] code, reason in
                let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self?.emitTerminal(gen, .closed(code: code.rawValue, reason: text))
            },
            onError: { [weak self] error in
                self?.emitTerminal(gen, .failed(.transport(.networkError(error.localizedDescription))))
            }
        )
        self.delegate = del

        let session = URLSession(configuration: .default, delegate: del, delegateQueue: nil)
        self.urlSession = session
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        startReceiveLoop(gen, task: t)
    }

    @discardableResult
    func send(_ data: Data) async -> Bool {
        let (t, gen): (URLSessionWebSocketTask?, Int) = withLock { (task, generation) }
        guard let t, let string = String(data: data, encoding: .utf8) else { return false }
        do {
            try await t.send(.string(string))
            return true
        } catch {
            emitTerminal(gen, .failed(.transport(.networkError(error.localizedDescription))))
            return false
        }
    }

    func close() async {
        markTerminated()
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        delegate = nil
    }

    // MARK: - Internal

    /// Synchronous critical section (safe to call from async contexts, unlike raw NSLock).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    /// Emit a non-terminal event, dropping it if it belongs to a superseded connection.
    private func emitCurrent(_ gen: Int, _ event: SignalingChannelEvent) {
        lock.lock()
        let current = gen == generation && !terminated
        lock.unlock()
        if current { caster.emit(event) }
    }

    /// Emit a terminal event exactly once per generation, dropping stale ones.
    private func emitTerminal(_ gen: Int, _ event: SignalingChannelEvent) {
        lock.lock()
        if gen != generation || terminated { lock.unlock(); return }
        terminated = true
        lock.unlock()
        caster.emit(event)
    }

    private func startReceiveLoop(_ gen: Int, task t: URLSessionWebSocketTask) {
        // Loop over the task captured at open() — never re-read self.task, which
        // may already belong to a newer connection.
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await t.receive()
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) { self?.emitCurrent(gen, .message(data)) }
                    case .data(let data):
                        self?.emitCurrent(gen, .message(data))
                    @unknown default:
                        break
                    }
                } catch {
                    break
                }
            }
        }
    }
}

/// `URLSessionWebSocketDelegate` for the signaling channel. Mirrors the chat
/// transport's delegate: open / close / handshake-failure callbacks.
private final class SignalingSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let onOpen: @Sendable () -> Void
    let onClose: @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void
    let onError: @Sendable (Error) -> Void

    init(
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onError = onError
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose(closeCode, reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        onError(error)
    }
}
