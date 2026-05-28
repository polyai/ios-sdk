// Copyright PolyAI Limited

import Foundation

struct SessionContext: Sendable {
    let platform: String
    let streamingEnabled: Bool

    init(
        platform: String,
        streamingEnabled: Bool
    ) {
        self.platform = platform
        self.streamingEnabled = streamingEnabled
    }
}

struct SessionCreated: Sendable {
    let sessionId: String
}

struct AccessTokenResponse: Sendable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String

    var tokenExpiresAt: Date {
        Date().addingTimeInterval(TimeInterval(expiresIn))
    }
}

protocol RestApiPort: Sendable {
    func obtainAccessToken() async throws -> AccessTokenResponse
    func createSession(context: SessionContext) async throws -> SessionCreated
    func currentAccessToken() async -> String?
}
