// Copyright PolyAI Limited

import Foundation
@testable import PolyMessaging

/// Three-part base64url-encoded JWT with `alg:none` header, empty payload,
/// and empty signature. Structurally valid (no `exp` claim = non-expiring
/// per web validator semantics), so it passes `JWTValidator.isStructurallyValid`.
/// Used as the fixture token in mock responses.
let testJWT = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.e30."

final class MockRestApi: RestApiPort, @unchecked Sendable {

    var obtainTokenResult: Result<AccessTokenResponse, Error> = .success(
        AccessTokenResponse(accessToken: testJWT, expiresIn: 3600, tokenType: "Bearer")
    )
    var createSessionResult: Result<SessionCreated, Error> = .success(
        SessionCreated(sessionId: "session_123")
    )

    var obtainTokenCallCount = 0
    var createSessionCallCount = 0
    var lastSessionContext: SessionContext?

    private var storedAccessToken: String?

    func obtainAccessToken() async throws -> AccessTokenResponse {
        obtainTokenCallCount += 1
        let result = try obtainTokenResult.get()
        storedAccessToken = result.accessToken
        return result
    }

    func createSession(context: SessionContext) async throws -> SessionCreated {
        createSessionCallCount += 1
        lastSessionContext = context
        return try createSessionResult.get()
    }

    func currentAccessToken() async -> String? {
        return storedAccessToken
    }

    func currentAccessTokenSync() -> String? {
        storedAccessToken
    }
}
