// Copyright PolyAI Limited

import Foundation

public struct SessionState: Sendable, Equatable {
    public let sessionId: String?
    public let status: SessionStatus
    public let isReady: Bool
    public let isLoading: Bool
    public let error: SessionErrorCode?
    public let hasInvalidConnectorToken: Bool

    public init(
        sessionId: String?, status: SessionStatus,
        isReady: Bool, isLoading: Bool,
        error: SessionErrorCode?,
        hasInvalidConnectorToken: Bool = false
    ) {
        self.sessionId = sessionId
        self.status = status
        self.isReady = isReady
        self.isLoading = isLoading
        self.error = error
        self.hasInvalidConnectorToken = hasInvalidConnectorToken
    }
}

public extension SessionState {
    var isError: Bool { hasInvalidConnectorToken || error != nil }
    var errorMessage: String? { hasInvalidConnectorToken ? "Invalid connector token" : error?.rawValue }
    var canSendMessages: Bool { isReady && !isError }
    var isTerminal: Bool { status == .ended || status == .expired }
}

public enum SessionStatus: String, Sendable {
    case unknown
    case active
    case ended
    case expired
    case restored
}

public enum SessionErrorCode: String, Sendable {
    case errorParsingRequest = "Error parsing request"
    case missingAuthHeaders = "Missing authentication headers"
    case connectorLookupFailed = "Unable to get agent details from connector service"
    case connectorValidationFailed = "Failed to validate connector"
    case sessionCreationFailed = "Error creating session"
    case unknown = "UNKNOWN_ERROR"
    case connectionClosedAbnormally = "Connection closed abnormally"
    case messageTooLarge = "Message too large"
}
