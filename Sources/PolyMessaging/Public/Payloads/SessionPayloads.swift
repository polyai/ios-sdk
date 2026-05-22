import Foundation

public struct SessionStartPayload: Sendable, Equatable {
    public let capabilities: SessionCapabilities
}

public struct SessionCapabilities: Sendable, Equatable {
    public let streaming: Bool
    public let maxMessageSize: Int
    public let heartbeatIntervalSeconds: Int?
    public let maxReconnectAttempts: Int?
}

public struct SessionEndPayload: Sendable, Equatable {
    public let reason: String?
}
