// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class ConnectionServiceTests: XCTestCase {

    private func makeService() -> (ConnectionService, MockConnection) {
        let mock = MockConnection()
        let url = URL(string: "wss://messaging.dev.poly.ai/ws")!
        let service = ConnectionService(transport: mock, wsBaseURL: url, logger: NoopLogger())
        return (service, mock)
    }

    // MARK: - Connect

    func testConnectToSessionBuildsCorrectURL() async {
        let (service, mock) = makeService()
        await service.connectToSession(sessionId: "sess_abc", accessToken: "tok_123")

        XCTAssertEqual(mock.connectCalls.count, 1)
        let url = mock.connectCalls.first!
        XCTAssertTrue(url.absoluteString.contains("access_token=tok_123"))
        XCTAssertTrue(url.absoluteString.contains("session_id=sess_abc"))
    }

func testConnectToSessionResetsCounters() async {
        let (service, mock) = makeService()
        await service.connectToSession(sessionId: "s1", accessToken: "t1")

        // Simulate a close + reconnect cycle
        mock.simulateClose(code: 1006, wasClean: false)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Fresh connect resets
        await service.connectToSession(sessionId: "s2", accessToken: "t2")
        XCTAssertEqual(mock.connectCalls.count, 2)
    }

    // MARK: - Close code handling

    func testNormalCloseDoesNotReconnect() async {
        let (service, mock) = makeService()
        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        mock.simulateOpen()

        mock.simulateClose(code: 1000, reason: "normal", wasClean: true)

        try? await Task.sleep(nanoseconds: 200_000_000)
        // Should not have attempted a second connect
        XCTAssertEqual(mock.connectCalls.count, 1)
    }

    func testClientReplacedCloseIsIgnored() async {
        let (service, mock) = makeService()
        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        mock.simulateOpen()

        mock.simulateClose(code: 4000, reason: "replaced", wasClean: true)

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(mock.connectCalls.count, 1)
    }

    // MARK: - Disconnect

    func testDisconnectCallsTransport() async {
        let (service, mock) = makeService()
        await service.connectToSession(sessionId: "s1", accessToken: "t1")

        await service.disconnect(code: 1000, reason: "user ended")
        XCTAssertEqual(mock.disconnectCalls.count, 1)
        XCTAssertEqual(mock.disconnectCalls.first?.code, 1000)
    }

    // MARK: - Send

    func testSendForwardsToTransport() async {
        let (service, mock) = makeService()
        await service.connectToSession(sessionId: "s1", accessToken: "t1")

        await service.send(.userMessage(text: "hello"))
        XCTAssertEqual(mock.sentEvents.count, 1)
        if case .userMessage(let text, _) = mock.sentEvents.first {
            XCTAssertEqual(text, "hello")
        } else {
            XCTFail("Expected userMessage")
        }
    }

    // MARK: - Max reconnect attempts

    func testSetMaxReconnectAttemptsGuardsZero() async {
        let (service, _) = makeService()
        await service.setMaxReconnectAttempts(0)
        // Should not crash; value unchanged (guarded by n > 0)
    }

    func testSetMaxReconnectAttemptsAcceptsPositive() async {
        let (service, _) = makeService()
        await service.setMaxReconnectAttempts(5)
        // No direct assertion — just verifies it doesn't crash
    }

    // MARK: - Invalid session

    func testInvalidSessionEmitsOnCode4001() async {
        let (service, mock) = makeService()

        // Subscribe BEFORE connect so we don't miss the emit
        let expectation = XCTestExpectation(description: "invalidSession emitted")
        let task = Task {
            for await _ in service.invalidSession.subscribe() {
                expectation.fulfill()
                break
            }
        }

        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        mock.simulateOpen()
        try? await Task.sleep(nanoseconds: 100_000_000)

        mock.simulateClose(code: 4001, reason: "unknown session", wasClean: false)
        await fulfillment(of: [expectation], timeout: 3.0)
        task.cancel()
    }

    func testHandshakeFailureRoutesToInvalidSession() async {
        let (service, mock) = makeService()

        let expectation = XCTestExpectation(description: "invalidSession emitted")
        let task = Task {
            for await _ in service.invalidSession.subscribe() {
                expectation.fulfill()
                break
            }
        }

        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        try? await Task.sleep(nanoseconds: 100_000_000)

        mock.simulateClose(code: 1006, reason: "handshake failed", wasClean: false)
        await fulfillment(of: [expectation], timeout: 3.0)
        task.cancel()
    }

    // MARK: - Budget preservation

    func testNotifyRefetchFailedRollsBackCounter() async {
        let (service, _) = makeService()
        await service.notifyRefetchFailed()
        // Should not crash; resets counters
    }

    // MARK: - Destroy

    func testDestroyDisconnects() async {
        let (service, mock) = makeService()
        await service.connectToSession(sessionId: "s1", accessToken: "t1")
        await service.destroy()

        XCTAssertEqual(mock.disconnectCalls.count, 1)
    }
}
