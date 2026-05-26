// Copyright PolyAI Limited

import Foundation

public enum ChatMessage: Identifiable, Equatable, Sendable {
    case user(UserMessage)
    case agent(AgentMessage)
    case system(SystemMessage)

    public var id: UUID {
        switch self {
        case .user(let m): return m.id
        case .agent(let m): return m.id
        case .system(let m): return m.id
        }
    }

    public var timestamp: Date {
        switch self {
        case .user(let m): return m.timestamp
        case .agent(let m): return m.timestamp
        case .system(let m): return m.timestamp
        }
    }

    public var text: String? {
        switch self {
        case .user(let m): return m.text
        case .agent(let m): return m.text
        case .system: return nil
        }
    }

    public var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    public var isSystem: Bool {
        if case .system = self { return true }
        return false
    }

    public var delivery: Delivery? {
        if case .user(let m) = self { return m.delivery }
        return nil
    }

    public var suggestions: [ResponseSuggestion] {
        if case .agent(let m) = self { return m.suggestions }
        return []
    }

    public var attachments: [Attachment] {
        if case .agent(let m) = self { return m.attachments }
        return []
    }
}

public struct UserMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let timestamp: Date
    public var delivery: Delivery
    public let draftId: String

    public init(id: UUID = UUID(), text: String, timestamp: Date = Date(), delivery: Delivery, draftId: String) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.delivery = delivery
        self.draftId = draftId
    }
}

public struct AgentMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let messageId: String
    public let agentName: String?
    public let agentKind: AgentKind
    public let avatarUrl: URL?
    public let text: String
    public let timestamp: Date
    public let attachments: [Attachment]
    public var suggestions: [ResponseSuggestion]
    public let callActions: [ChatCallAction]

    public init(
        id: UUID = UUID(),
        messageId: String,
        agentName: String?,
        agentKind: AgentKind,
        avatarUrl: URL? = nil,
        text: String,
        timestamp: Date = Date(),
        attachments: [Attachment] = [],
        suggestions: [ResponseSuggestion] = [],
        callActions: [ChatCallAction] = []
    ) {
        self.id = id
        self.messageId = messageId
        self.agentName = agentName
        self.agentKind = agentKind
        self.avatarUrl = avatarUrl
        self.text = text
        self.timestamp = timestamp
        self.attachments = attachments
        self.suggestions = suggestions
        self.callActions = callActions
    }
}

public struct SystemMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let event: SystemEvent
    public let timestamp: Date

    public init(id: UUID = UUID(), event: SystemEvent, timestamp: Date = Date()) {
        self.id = id
        self.event = event
        self.timestamp = timestamp
    }
}

public enum AgentKind: Sendable, Equatable {
    case poly
    case live
}

public enum Delivery: Sendable, Equatable {
    case pending
    case sent
    case failed
}

public enum SystemEvent: Sendable, Equatable {
    case conversationEnded(reason: String?)
    case agentLeft(reason: String?)
    case liveAgentJoined(name: String?)
    case liveAgentLeft(reason: String?)
    case queueStatus(position: Int?, displayMessage: String?)
    case handoffStarted
    case handoffRequired(reason: String)
    case handoffAccepted
    case handoffFailed(reason: String?)
    case handoffTimeout
    case idleWarning
    case serverMessage(text: String, level: SystemMessageLevel)
}

public extension SystemEvent {
    var isHandoff: Bool {
        switch self {
        case .handoffStarted, .handoffRequired, .handoffAccepted, .handoffFailed, .handoffTimeout:
            return true
        default:
            return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .conversationEnded, .liveAgentLeft, .handoffFailed, .handoffTimeout:
            return true
        default:
            return false
        }
    }

    var reason: String? {
        switch self {
        case .conversationEnded(let reason), .agentLeft(let reason), .liveAgentLeft(let reason), .handoffFailed(let reason):
            return reason
        case .liveAgentJoined(let name):
            return name
        case .handoffRequired(let reason):
            return reason
        default:
            return nil
        }
    }
}

@available(*, deprecated, renamed: "ConnectionStatus")
public typealias ConnectionState = ConnectionStatus
