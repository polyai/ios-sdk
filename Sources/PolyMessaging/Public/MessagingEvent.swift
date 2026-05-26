// Copyright PolyAI Limited

import Foundation

public enum MessagingEvent: Sendable {

    // MARK: - Session lifecycle

    case sessionStart(Envelope, SessionStartPayload)
    case sessionEnd(Envelope, SessionEndPayload)
    case sessionIdleWarning(Envelope)

    // MARK: - User (echoed back by server)

    case userMessage(Envelope, UserMessageEchoPayload)
    case userTyping(Envelope)
    case userEndSession(Envelope)
    case requestPolyAgentJoin(Envelope)
    case messagePending(draftId: String, text: String)
    case messageConfirmed(draftId: String, messageId: String)
    case messageFailed(draftId: String)

    // MARK: - PolyAgent

    case agentJoined(Envelope, AgentJoinedPayload)
    case agentThinking(Envelope)
    case agentMessage(Envelope, AgentMessagePayload)
    case agentMessageChunk(Envelope, AgentMessageChunkPayload)
    case agentLeft(Envelope, AgentLeftPayload)
    case agentTriggeredHandoff(Envelope)

    // MARK: - Live agent

    case liveAgentJoined(Envelope, LiveAgentJoinedPayload)
    case liveAgentTyping(Envelope, LiveAgentTypingPayload)
    case liveAgentMessage(Envelope, LiveAgentMessagePayload)
    case liveAgentLeft(Envelope, LiveAgentLeftPayload)

    // MARK: - System

    case systemMessage(Envelope, SystemMessagePayload)
    case heartbeat(Envelope)

    // MARK: - Handoff

    case clientHandoffRequired(Envelope, ClientHandoffRequiredPayload)
    case handoffQueueStatus(Envelope, HandoffQueueStatusPayload)
    case handoffAccepted(Envelope, HandoffAcceptedPayload)
    case handoffFailed(Envelope, HandoffFailedPayload)
    case handoffTimeout(Envelope, HandoffTimeoutPayload)

    // MARK: - Connection lifecycle

    case connected
    case reconnecting(attempt: Int)
    case disconnected(PolyError?)
}

extension MessagingEvent {
    public var envelope: Envelope? {
        switch self {
        case .sessionStart(let e, _), .sessionEnd(let e, _), .sessionIdleWarning(let e),
             .userMessage(let e, _), .userTyping(let e), .userEndSession(let e),
             .requestPolyAgentJoin(let e),
             .agentJoined(let e, _), .agentThinking(let e),
             .agentMessage(let e, _), .agentMessageChunk(let e, _),
             .agentLeft(let e, _), .agentTriggeredHandoff(let e),
             .liveAgentJoined(let e, _), .liveAgentTyping(let e, _),
             .liveAgentMessage(let e, _), .liveAgentLeft(let e, _),
             .systemMessage(let e, _), .heartbeat(let e),
             .clientHandoffRequired(let e, _), .handoffQueueStatus(let e, _),
             .handoffAccepted(let e, _), .handoffFailed(let e, _),
             .handoffTimeout(let e, _):
            return e
        case .connected, .disconnected, .reconnecting,
             .messagePending, .messageConfirmed, .messageFailed:
            return nil
        }
    }
}

extension MessagingEvent {
    public var isConnectionEvent: Bool {
        switch self {
        case .connected, .reconnecting, .disconnected: return true
        default: return false
        }
    }

    public var isHandoffEvent: Bool {
        switch self {
        case .clientHandoffRequired, .handoffQueueStatus, .handoffAccepted,
             .handoffFailed, .handoffTimeout, .agentTriggeredHandoff: return true
        default: return false
        }
    }

    public var isAgentEvent: Bool {
        switch self {
        case .agentJoined, .agentThinking, .agentMessage,
             .agentMessageChunk, .agentLeft: return true
        default: return false
        }
    }

    public var isLiveAgentEvent: Bool {
        switch self {
        case .liveAgentJoined, .liveAgentTyping,
             .liveAgentMessage, .liveAgentLeft: return true
        default: return false
        }
    }

    public var isDeliveryEvent: Bool {
        switch self {
        case .messagePending, .messageConfirmed, .messageFailed: return true
        default: return false
        }
    }
}

public struct Envelope: Sendable, Equatable {
    public let id: String
    public let sequence: Int?
    public let timestamp: Date
    public let metadata: EventMetadata?

    public init(id: String, sequence: Int?, timestamp: Date, metadata: EventMetadata? = nil) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

public struct EventMetadata: Sendable, Equatable {
    public let custom: [String: String]?

    public init(custom: [String: String]? = nil) {
        self.custom = custom
    }
}
