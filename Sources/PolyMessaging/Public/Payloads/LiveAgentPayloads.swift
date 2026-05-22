import Foundation

public struct LiveAgentJoinedPayload: Sendable, Equatable {
    public let agentId: String?
    public let agentName: String?
    public let avatarUrl: URL?
}

public struct LiveAgentTypingPayload: Sendable, Equatable {
    public let state: TypingState
    public let agentId: String?
    public let agentName: String?
}

public struct LiveAgentMessagePayload: Sendable, Equatable {
    public let messageId: String
    public let text: String
    public let agentId: String?
    public let agentName: String?
    public let avatarUrl: URL?
    public let attachments: [Attachment]
    public let responseSuggestions: [ResponseSuggestion]
    public let chatCallActions: [ChatCallAction]
}

public struct LiveAgentLeftPayload: Sendable, Equatable {
    public let agentId: String?
    public let agentName: String?
    public let reason: String?
}
