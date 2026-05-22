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
    /// Send a pre-encoded JSON frame.
    func send(_ data: Data) async
    /// Close the socket and stop emitting events.
    func close() async
    var events: AsyncStream<SignalingChannelEvent> { get }
}

/// `URLSessionWebSocketTask`-backed signaling channel for
/// `wss://webrtc-gateway.<env>.polyai.app/api/v1/webrtc/signal`.
///
/// Deliberately leaner than `WebSocketTransport`: the gateway speaks its own
/// JSON envelope (offer/answer/ice-candidate), so frames are surfaced raw via
/// `.message(Data)` and parsed by `SignalingProtocol` upstream rather than the
/// chat `WireDecoder`.
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

    init(url: URL, logger: PolyLogger) {
        self.url = url
        self.logger = logger
    }

    var events: AsyncStream<SignalingChannelEvent> { caster.subscribe() }

    func open() async {
        logger.debug("Opening signaling WS", metadata: ["host": url.host ?? "unknown"])
        let del = SignalingSocketDelegate(
            onOpen: { [weak self] in self?.caster.emit(.opened) },
            onClose: { [weak self] code, reason in
                let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self?.emitTerminal(.closed(code: code.rawValue, reason: text))
            },
            onError: { [weak self] error in
                self?.emitTerminal(.failed(.transport(.networkError(error.localizedDescription))))
            }
        )
        self.delegate = del

        let session = URLSession(configuration: .default, delegate: del, delegateQueue: nil)
        self.urlSession = session
        let t = session.webSocketTask(with: url)
        self.task = t
        t.resume()
        startReceiveLoop()
    }

    func send(_ data: Data) async {
        guard let t = task, let string = String(data: data, encoding: .utf8) else { return }
        do {
            try await t.send(.string(string))
        } catch {
            emitTerminal(.failed(.transport(.networkError(error.localizedDescription))))
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

    private func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    private func emitTerminal(_ event: SignalingChannelEvent) {
        lock.lock()
        if terminated { lock.unlock(); return }
        terminated = true
        lock.unlock()
        caster.emit(event)
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let t = self.task else { break }
                do {
                    let message = try await t.receive()
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) { self.caster.emit(.message(data)) }
                    case .data(let data):
                        self.caster.emit(.message(data))
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
