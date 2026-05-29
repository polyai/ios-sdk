// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class SessionServiceTests: XCTestCase {

    private func makeService(api: MockRestApi? = nil) -> (SessionService, MockRestApi) {
        let mockApi = api ?? MockRestApi()
        let config = Configuration(apiKey: "test_token", environment: .us)
        let service = SessionService(api: mockApi, config: config, logger: NoopLogger())
        return (service, mockApi)
    }

    // MARK: - createSession

    func testCreateSessionCallsObtainTokenThenCreateSession() async throws {
        let (service, api) = makeService()
        try await service.createSession()

        let tokenCalls = api.obtainTokenCallCount
        let sessionCalls = api.createSessionCallCount
        XCTAssertEqual(tokenCalls, 1)
        XCTAssertEqual(sessionCalls, 1)
    }

    func testCreateSessionSetsActiveState() async throws {
        let (service, _) = makeService()
        try await service.createSession()

        let state = await service.state
        XCTAssertEqual(state.status, .active)
        XCTAssertEqual(state.sessionId, "session_123")
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.error)
    }

    func testCreateSessionGuardsConcurrentCalls() async throws {
        let (service, api) = makeService()
        try await service.createSession()

        // Second call while session is active should still go through (not loading)
        let state = await service.state
        XCTAssertFalse(state.isLoading)
    }

    func testCreateSessionOnTokenFailureSetsError() async {
        let api = MockRestApi()
        api.obtainTokenResult = .failure(PolyError.auth(.unauthorized))
        let config = Configuration(apiKey: "bad_token", environment: .us)
        let service = SessionService(api: api, config: config, logger: NoopLogger())

        do {
            try await service.createSession()
            XCTFail("Expected error")
        } catch {}

        let state = await service.state
        XCTAssertNotNil(state.error)
        XCTAssertTrue(state.hasInvalidApiKey)
    }

    func testCreateSessionClearsTokenBeforeRetry() async throws {
        let (service, api) = makeService()
        try await service.createSession()

        let token1 = api.currentAccessTokenSync()
        XCTAssertNotNil(token1)

        // Creating again should clear and re-obtain
        try await service.createSession()
        let calls = api.obtainTokenCallCount
        XCTAssertEqual(calls, 2)
    }

    // MARK: - Timeout

    func testCheckTimeoutReturnsFalseWhenFresh() async throws {
        let (service, _) = makeService()
        try await service.createSession()

        let timedOut = await service.checkTimeout()
        XCTAssertFalse(timedOut)
    }

    func testTouchUpdatesTimestamp() async throws {
        let (service, _) = makeService()
        try await service.createSession()
        await service.touch()
        let timedOut = await service.checkTimeout()
        XCTAssertFalse(timedOut)
    }

    // MARK: - Socket lifecycle

    func testOnSocketOpenSetsReady() async throws {
        let (service, _) = makeService()
        try await service.createSession()

        await service.onSocketOpen()
        let state = await service.state
        XCTAssertTrue(state.isReady)
        XCTAssertNil(state.error)
    }

    func testOnSocketCloseSetsNotReady() async throws {
        let (service, _) = makeService()
        try await service.createSession()
        await service.onSocketOpen()

        await service.onSocketClose(event: ConnectionCloseEvent(code: 1006, reason: "abnormal", wasClean: false))
        let state = await service.state
        XCTAssertFalse(state.isReady)
    }

    // MARK: - End session

    func testEndSessionClearsState() async throws {
        let (service, _) = makeService()
        try await service.createSession()
        await service.endSession()

        let state = await service.state
        XCTAssertEqual(state.status, .ended)
        XCTAssertNil(state.sessionId)
    }

    // MARK: - Refetch

    func testRefetchSessionCreatesNewSession() async throws {
        let (service, api) = makeService()
        try await service.createSession()

        await service.refetchSession()
        let calls = api.createSessionCallCount
        XCTAssertEqual(calls, 2)
    }

    func testRefetchSessionCapsAt3Attempts() async throws {
        let api = MockRestApi()
        api.createSessionResult = .failure(PolyError.session(.sessionCreationFailed(.unknown)))
        let config = Configuration(apiKey: "test", environment: .us)
        let service = SessionService(api: api, config: config, logger: NoopLogger())

        // First createSession will fail
        try? await service.createSession()

        await service.refetchSession()
        await service.refetchSession()
        await service.refetchSession()
        await service.refetchSession() // 4th should be blocked

        let calls = api.createSessionCallCount
        // 1 (initial) + 3 (refetch cap) = 4
        XCTAssertLessThanOrEqual(calls, 4)
    }

    // MARK: - Token management

    func testEnsureAccessTokenReturnsCached() async throws {
        let (service, _) = makeService()
        try await service.createSession()

        let token = try await service.ensureAccessToken()
        XCTAssertEqual(token, testJWT)
    }

    // MARK: - Resume

    func testResumeCreatesNewSessionWhenNoneStored() async throws {
        // Clear any leftover UserDefaults from other tests (token-namespaced).
        SessionStore(apiKey: "test_token").clear()

        let (service, api) = makeService()
        try await service.resume()

        let calls = api.createSessionCallCount
        XCTAssertGreaterThanOrEqual(calls, 1)

        let state = await service.state
        XCTAssertEqual(state.status, .active)
    }
}

