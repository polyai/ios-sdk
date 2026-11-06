// Copyright PolyAI Limited

import Foundation

public struct SessionStartPayload: Sendable, Equatable {
    public let capabilities: SessionCapabilities
    public let contextId: String?

    init(capabilities: SessionCapabilities, contextId: String? = nil) {
        self.capabilities = capabilities
        self.contextId = contextId
    }
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
