// Copyright PolyAI Limited

import Foundation

/// Passed to `Configuration.onContextRequired`. Sign a JWT with `sub = contextId`.
public struct VerifiedContextRequest: Sendable, Equatable {
    public let sessionId: String
    public let contextId: String

    public init(sessionId: String, contextId: String) {
        self.sessionId = sessionId
        self.contextId = contextId
    }
}

/// Returns a JWT signed by your backend, or `nil` to skip. Capped at 4s.
public typealias VerifiedContextHandler = @Sendable (VerifiedContextRequest) async throws -> String?

/// Outcome of the verified-context step. Never blocks the chat — the agent always joins.
public enum VerifiedContextStatus: Sendable, Equatable {
    case idle
    case pending
    case set
    /// The handler returned `nil` or an empty string.
    case declined
    case failed(PolyError.VerifiedContext)
}
