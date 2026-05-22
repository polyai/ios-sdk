import Foundation

public struct AgentJoinedPayload: Sendable, Equatable {
    public let agentName: String?
    public let avatarUrl: URL?
}

public struct AgentMessagePayload: Sendable, Equatable {
    public let messageId: String
    public let text: String
    public let agentName: String?
    public let avatarUrl: URL?
    public let attachments: [Attachment]
    public let responseSuggestions: [ResponseSuggestion]
    public let chatCallActions: [ChatCallAction]
    public let endConversation: Bool
}

public struct AgentMessageChunkPayload: Sendable, Equatable {
    public let messageId: String
    public let chunkIndex: Int
    public let isComplete: Bool
    public let text: String?
    public let attachments: [Attachment]
    public let responseSuggestions: [ResponseSuggestion]
}

public struct AgentLeftPayload: Sendable, Equatable {
    public let reason: String?
}
