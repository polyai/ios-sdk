// Copyright PolyAI Limited

import Foundation

public protocol Connection: Sendable {
    func connect(url: URL) async
    func disconnect(code: Int, reason: String) async
    func send(_ event: OutgoingEvent) async
    /// Send raw bytes on the open WebSocket.
    /// Throws `PolyError.transport(.notConnected)` if no active task exists
    /// (typically the brief window between an old socket tearing down and
    /// a new one being established). Callers that wish to fire-and-forget
    /// should `try?` the call; callers that need to retry should await a
    /// reconnect (e.g. via `ChatService`'s retry ladder) before re-sending.
    func sendRaw(_ data: Data) async throws

    var status: ConnectionStatus { get async }
    var openEvents: AsyncStream<Void> { get }
    var closeEvents: AsyncStream<ConnectionCloseEvent> { get }
    var messages: AsyncStream<MessagingEvent> { get }
    var batchEvents: AsyncStream<[MessagingEvent]> { get }
    var rawFrames: AsyncStream<Data> { get }
    var errors: AsyncStream<PolyError> { get }
}

public extension Connection {
    /// Cleanly disconnect with the default WebSocket close code (1000) and
    /// empty reason. Convenience over `disconnect(code:reason:)`.
    func disconnect() async {
        await disconnect(code: 1000, reason: "")
    }
}
