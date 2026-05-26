import Foundation

public enum OutgoingEvent: Sendable, Equatable {
    case userMessage(text: String, metadata: [String: String]? = nil)
    case userEndConversation
    case userLeft
    case requestPolyAgentJoin
    case heartbeat
    case userTyping(TypingState)
}
