// Copyright PolyAI Limited

import Foundation
@_spi(PolyVoice) @testable import PolyMessaging

struct NoopLogger: PolyLogger {
    func debug(_ message: String, metadata: [String: any Sendable]?) {}
    func info(_ message: String, metadata: [String: any Sendable]?) {}
    func warn(_ message: String, metadata: [String: any Sendable]?) {}
    func error(_ message: String, metadata: [String: any Sendable]?) {}
}

/// Records what a verified-context handler was asked for, across concurrency domains.
actor HandlerRecorder {
    private(set) var requests: [VerifiedContextRequest] = []
    func record(_ request: VerifiedContextRequest) { requests.append(request) }
}

/// Holds a verified-context handler open until the test calls `open()`.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

func makeEnvelope(id: String = "evt_1", sequence: Int? = 1) -> Envelope {
    Envelope(id: id, sequence: sequence, timestamp: Date(), metadata: nil)
}

func makeSessionStartPayload(
    streaming: Bool = true,
    maxMessageSize: Int = 65536,
    heartbeatInterval: Int? = 30,
    maxReconnects: Int? = 10,
    contextId: String? = nil
) -> SessionStartPayload {
    SessionStartPayload(capabilities: SessionCapabilities(
        streaming: streaming,
        maxMessageSize: maxMessageSize,
        heartbeatIntervalSeconds: heartbeatInterval,
        maxReconnectAttempts: maxReconnects
    ), contextId: contextId)
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
