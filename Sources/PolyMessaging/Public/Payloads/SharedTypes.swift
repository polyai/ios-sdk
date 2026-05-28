// Copyright PolyAI Limited

import Foundation

public struct Attachment: Sendable, Equatable {
    public let contentType: AttachmentContentType
    public let contentUrl: URL?
    public let title: String?
    public let previewImageUrl: URL?
    public let callToActionText: String?
}

public enum AttachmentContentType: String, Sendable, Codable {
    case image = "ATTACHMENT_CONTENT_TYPE_IMAGE"
    case url = "ATTACHMENT_CONTENT_TYPE_URL"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AttachmentContentType(rawValue: raw) ?? .unknown
    }
}

public struct ResponseSuggestion: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let messageText: String
    public let payload: String?

    public init(id: UUID = UUID(), messageText: String, payload: String? = nil) {
        self.id = id
        self.messageText = messageText
        self.payload = payload
    }
}

public struct ChatCallAction: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let contactNumber: String

    public init(id: UUID = UUID(), title: String, contactNumber: String) {
        self.id = id
        self.title = title
        self.contactNumber = contactNumber
    }
}

public struct UserMessageEchoPayload: Sendable, Equatable {
    public let messageId: String
    public let text: String
}

public struct SystemMessagePayload: Sendable, Equatable {
    public let message: String
    public let level: SystemMessageLevel
}

public enum SystemMessageLevel: String, Sendable {
    case info = "SYSTEM_MESSAGE_LEVEL_INFO"
    case warning = "SYSTEM_MESSAGE_LEVEL_WARNING"
    case error = "SYSTEM_MESSAGE_LEVEL_ERROR"
}

public struct HandoffQueueStatusPayload: Sendable, Equatable {
    public let position: Int?
    public let estimatedWaitSeconds: Int?
    public let queueName: String?
    public let displayMessage: String?
}

public struct HandoffAcceptedPayload: Sendable, Equatable {
    public let queueName: String?
}

public struct HandoffFailedPayload: Sendable, Equatable {
    public let reason: String?
}

public struct HandoffTimeoutPayload: Sendable, Equatable {
    public let reason: String?
}

public struct ClientHandoffRequiredPayload: Sendable, Equatable {
    public let route: String?
    public let reason: String?
    public let queueName: String?
}
