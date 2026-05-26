// Copyright PolyAI Limited

import Foundation

public protocol Connection: Sendable {
    func connect(url: URL) async
    func disconnect(code: Int, reason: String) async
    func send(_ event: OutgoingEvent) async
    func sendRaw(_ data: Data) async

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
