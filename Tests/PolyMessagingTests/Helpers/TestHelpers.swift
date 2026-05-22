import Foundation
@testable import PolyMessaging

struct NoopLogger: PolyLogger {
    func debug(_ message: String, metadata: [String: any Sendable]?) {}
    func info(_ message: String, metadata: [String: any Sendable]?) {}
    func warn(_ message: String, metadata: [String: any Sendable]?) {}
    func error(_ message: String, metadata: [String: any Sendable]?) {}
}

func makeEnvelope(id: String = "evt_1", sequence: Int? = 1) -> Envelope {
    Envelope(id: id, sequence: sequence, timestamp: Date(), metadata: nil)
}

func makeSessionStartPayload(
    streaming: Bool = true,
    maxMessageSize: Int = 65536,
    heartbeatInterval: Int? = 30,
    maxReconnects: Int? = 10
) -> SessionStartPayload {
    SessionStartPayload(capabilities: SessionCapabilities(
        streaming: streaming,
        maxMessageSize: maxMessageSize,
        heartbeatIntervalSeconds: heartbeatInterval,
        maxReconnectAttempts: maxReconnects
    ))
}

func makeAgentMessagePayload(
    messageId: String = "msg_1",
    text: String = "Hello",
    endConversation: Bool = false
) -> AgentMessagePayload {
    AgentMessagePayload(
        messageId: messageId, text: text,
        agentName: nil, avatarUrl: nil,
        attachments: [], responseSuggestions: [],
        chatCallActions: [], endConversation: endConversation
    )
}

func makeChunkPayload(
    messageId: String = "msg_1",
    chunkIndex: Int = 0,
    isComplete: Bool = false,
    text: String? = "chunk"
) -> AgentMessageChunkPayload {
    AgentMessageChunkPayload(
        messageId: messageId, chunkIndex: chunkIndex,
        isComplete: isComplete, text: text,
        attachments: [], responseSuggestions: []
    )
}

/// Collects N events from a Multicaster into an array.
func collect<T>(_ stream: AsyncStream<T>, count: Int, timeout: TimeInterval = 10.0) async -> [T] {
    var results: [T] = []
    let task = Task {
        for await value in stream {
            results.append(value)
            if results.count >= count { break }
        }
    }
    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
    task.cancel()
    return results
}
