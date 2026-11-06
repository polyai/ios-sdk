// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

final class VerifiedContextServiceTests: XCTestCase {

    private let request = VerifiedContextRequest(sessionId: "session_123", contextId: "ctx_abc")

    private func makeService(
        api: MockRestApi = MockRestApi(),
        handlerTimeout: TimeInterval = 0.3,
        totalBudget: TimeInterval = 0.6,
        handler: @escaping VerifiedContextHandler
    ) -> VerifiedContextService {
        VerifiedContextService(
            handler: handler,
            api: api,
            logger: NoopLogger(),
            handlerTimeout: handlerTimeout,
            totalBudget: totalBudget
        )
    }

    func testTokenIsSubmittedAndStatusIsSet() async {
        let api = MockRestApi()
        let recorder = HandlerRecorder()
        let service = makeService(api: api) { req in
            await recorder.record(req)
            return "signed.jwt.token"
        }

        let status = await service.run(request)

        XCTAssertEqual(status, .set)
        let requests = await recorder.requests
        XCTAssertEqual(requests, [request])
        XCTAssertEqual(api.submittedContexts.count, 1)
        XCTAssertEqual(api.submittedContexts.first?.sessionId, "session_123")
        XCTAssertEqual(api.submittedContexts.first?.token, "signed.jwt.token")
    }

    func testNotifyAgentIsPassedToSubmit() async {
        let api = MockRestApi()
        let service = makeService(api: api) { _ in "signed.jwt.token" }

        _ = await service.run(request)
        _ = await service.run(request, notifyAgent: true)

        XCTAssertEqual(api.submittedContexts.map(\.notifyAgent), [false, true])
    }

    func testNilTokenDeclinesWithoutSubmitting() async {
        let api = MockRestApi()
        let status = await makeService(api: api) { _ in nil }.run(request)
        XCTAssertEqual(status, .declined)
        XCTAssertTrue(api.submittedContexts.isEmpty)
    }

    func testEmptyTokenDeclinesWithoutSubmitting() async {
        let api = MockRestApi()
        let status = await makeService(api: api) { _ in "" }.run(request)
        XCTAssertEqual(status, .declined)
        XCTAssertTrue(api.submittedContexts.isEmpty)
    }

    func testThrowingHandlerFails() async {
        struct SigningDown: Error, CustomStringConvertible { var description: String { "signing down" } }
        let api = MockRestApi()
        let status = await makeService(api: api) { _ in throw SigningDown() }.run(request)
        XCTAssertEqual(status, .failed(.callbackFailed("signing down")))
        XCTAssertTrue(api.submittedContexts.isEmpty)
    }

    func testHandlerThatIgnoresCancellationStillTimesOut() async {
        let api = MockRestApi()
        let service = makeService(api: api, handlerTimeout: 0.2) { _ in
            // `try?` swallows cancellation — the deadline must not wait for this.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return "too.late"
        }

        let started = Date()
        let status = await service.run(request)

        XCTAssertEqual(status, .failed(.callbackTimedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertTrue(api.submittedContexts.isEmpty)
    }

    func testVerificationFailureIsSurfaced() async {
        let api = MockRestApi()
        api.submitContextResult = .failure(PolyError.verifiedContext(.verificationFailed("invalid token signature")))
        let status = await makeService(api: api) { _ in "bad.sig.token" }.run(request)
        XCTAssertEqual(status, .failed(.verificationFailed("invalid token signature")))
    }

    func testNonContextSubmitErrorIsWrappedAsSubmitFailed() async {
        let api = MockRestApi()
        api.submitContextResult = .failure(URLError(.notConnectedToInternet))
        let status = await makeService(api: api) { _ in "a.b.c" }.run(request)
        guard case .failed(.submitFailed) = status else {
            return XCTFail("Expected submitFailed, got \(status)")
        }
    }

    func testSlowSubmitIsCappedByTotalBudget() async {
        let api = MockRestApi()
        api.submitContextDelay = 3
        let service = makeService(api: api, handlerTimeout: 0.2, totalBudget: 0.4) { _ in "a.b.c" }

        let started = Date()
        let status = await service.run(request)

        XCTAssertEqual(status, .failed(.submitFailed("Timed out")))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    // MARK: - Request body

    func testRequestBodyOnlyCarriesNotifyAgentWhenAsked() {
        let quiet = RestApi.contextRequestBody(token: "a.b.c", notifyAgent: false)
        XCTAssertEqual(Set(quiet.keys), ["token"])
        XCTAssertEqual(quiet["token"] as? String, "a.b.c")

        let notify = RestApi.contextRequestBody(token: "a.b.c", notifyAgent: true)
        XCTAssertEqual(Set(notify.keys), ["token", "notify_agent"])
        XCTAssertEqual(notify["notify_agent"] as? Bool, true)
    }

    // MARK: - HTTP status mapping

    func testContextErrorMapping() {
        func body(_ message: String) -> Data { try! JSONSerialization.data(withJSONObject: ["message": message]) }

        XCTAssertEqual(RestApi.mapContextError(statusCode: 401, data: body("unknown signing key")), .verifiedContext(.verificationFailed("unknown signing key")))
        // A non-JSON body (e.g. an edge proxy's error page) falls back to the status.
        let xml = Data(#"<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>"#.utf8)
        XCTAssertEqual(RestApi.mapContextError(statusCode: 403, data: xml), .verifiedContext(.verificationFailed("HTTP 403")))
        XCTAssertEqual(RestApi.mapContextError(statusCode: 400, data: body("token is required")), .verifiedContext(.invalidToken("token is required")))
        XCTAssertEqual(RestApi.mapContextError(statusCode: 413, data: Data()), .verifiedContext(.invalidToken("HTTP 413")))
        XCTAssertEqual(RestApi.mapContextError(statusCode: 404, data: Data()), .verifiedContext(.submitFailed("HTTP 404")))
    }

    // MARK: - Storage

    func testContextSubmitSessionHasNoCache() {
        let api = RestApi(
            baseURL: URL(string: "https://messaging.poly.ai/api/v1")!,
            apiKey: "test_token",
            hostIdentifier: "ai.poly.tests",
            logger: NoopLogger()
        )
        // The default URLCache archives POST bodies to disk; the signed token
        // must never land there.
        XCTAssertNil(api.noStoreSession.configuration.urlCache)
        XCTAssertEqual(api.noStoreSession.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    // MARK: - Wire

    func testSessionStartDecodesContextId() {
        let json = """
        {
            "id": "evt_001", "sequence": 1, "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_SESSION_START",
            "payload": { "capabilities": { "streaming": true }, "context_id": "ctx_a1b2c3" }
        }
        """.data(using: .utf8)!

        guard case .sessionStart(_, let payload) = WireDecoder.decode(json).first else {
            return XCTFail("Expected sessionStart")
        }
        XCTAssertEqual(payload.contextId, "ctx_a1b2c3")
    }

    func testSessionStartWithoutContextIdDecodesNil() {
        let json = """
        {
            "id": "evt_001", "sequence": 1, "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_SESSION_START",
            "payload": { "capabilities": { "streaming": true } }
        }
        """.data(using: .utf8)!

        guard case .sessionStart(_, let payload) = WireDecoder.decode(json).first else {
            return XCTFail("Expected sessionStart")
        }
        XCTAssertNil(payload.contextId)
    }
}
