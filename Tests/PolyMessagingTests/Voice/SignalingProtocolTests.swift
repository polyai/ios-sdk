import XCTest
@testable import PolyMessaging

/// Unit tests for the WebRTC signaling wire framing — the pure parser/builder
/// that the live gateway round-trip depends on.
final class SignalingProtocolTests: XCTestCase {

    // MARK: - Parsing

    func test_parse_answer_withSessionId() {
        let data = json(["type": "answer", "sessionId": "sig_1", "data": ["type": "answer", "sdp": "v=0..."]])
        guard case .answer(let sessionId, let sdp) = SignalingProtocol.parse(data) else {
            return XCTFail("expected answer")
        }
        XCTAssertEqual(sessionId, "sig_1")
        XCTAssertEqual(sdp, "v=0...")
    }

    func test_parse_answer_withoutSessionId() {
        let data = json(["type": "answer", "data": ["type": "answer", "sdp": "v=0..."]])
        guard case .answer(let sessionId, _) = SignalingProtocol.parse(data) else {
            return XCTFail("expected answer")
        }
        XCTAssertNil(sessionId)
    }

    func test_parse_iceCandidate() {
        let data = json([
            "type": "ice-candidate",
            "data": ["candidate": "candidate:1 1 udp ...", "sdpMid": "0", "sdpMLineIndex": 0],
        ])
        guard case .iceCandidate(let candidate) = SignalingProtocol.parse(data) else {
            return XCTFail("expected ice-candidate")
        }
        XCTAssertEqual(candidate.candidate, "candidate:1 1 udp ...")
        XCTAssertEqual(candidate.sdpMid, "0")
        XCTAssertEqual(candidate.sdpMLineIndex, 0)
    }

    func test_parse_error_usesMessage() {
        let data = json(["type": "error", "data": ["message": "bad token"]])
        XCTAssertEqual(SignalingProtocol.parse(data), .error(message: "bad token"))
    }

    func test_parse_error_defaultsMessage() {
        let data = json(["type": "error"])
        XCTAssertEqual(SignalingProtocol.parse(data), .error(message: "Connection failed"))
    }

    func test_parse_pong_and_close() {
        XCTAssertEqual(SignalingProtocol.parse(json(["type": "pong"])), .pong)
        XCTAssertEqual(SignalingProtocol.parse(json(["type": "close"])), .close)
    }

    func test_parse_malformed_returnsNil() {
        XCTAssertNil(SignalingProtocol.parse(Data("not json".utf8)))
        XCTAssertNil(SignalingProtocol.parse(json(["noType": "x"])))
        XCTAssertNil(SignalingProtocol.parse(json(["type": "answer", "data": ["type": "answer"]])))  // no sdp
        XCTAssertNil(SignalingProtocol.parse(json(["type": "totally-unknown"])))
    }

    // MARK: - Building

    func test_offer_shape_newSession() throws {
        let data = try XCTUnwrap(SignalingProtocol.offer(
            sdp: "v=0-offer", authToken: "tok_123", callSid: "call_abc", sessionId: nil
        ))
        let obj = try decode(data)
        XCTAssertEqual(obj["type"] as? String, "offer")
        XCTAssertEqual(obj["mode"] as? String, "end-to-end")
        XCTAssertEqual(obj["authToken"] as? String, "tok_123")
        XCTAssertEqual(obj["callSid"] as? String, "call_abc")
        XCTAssertEqual(obj["caller"] as? String, "Polyphone")
        XCTAssertEqual(obj["callee"] as? String, "Polyphone")
        XCTAssertTrue(obj["sessionId"] is NSNull, "new-session offer carries an explicit null sessionId")
        let inner = try XCTUnwrap(obj["data"] as? [String: Any])
        XCTAssertEqual(inner["type"] as? String, "offer")
        XCTAssertEqual(inner["sdp"] as? String, "v=0-offer")
    }

    func test_offer_shape_withSessionId() throws {
        let data = try XCTUnwrap(SignalingProtocol.offer(
            sdp: "v=0", authToken: "t", callSid: "c", sessionId: "sig_9"
        ))
        let obj = try decode(data)
        XCTAssertEqual(obj["sessionId"] as? String, "sig_9")
    }

    func test_iceCandidate_shape() throws {
        let candidate = ICECandidate(candidate: "candidate:xyz", sdpMid: "0", sdpMLineIndex: 1)
        let data = try XCTUnwrap(SignalingProtocol.iceCandidate(candidate, sessionId: "sig_1"))
        let obj = try decode(data)
        XCTAssertEqual(obj["type"] as? String, "ice-candidate")
        XCTAssertEqual(obj["sessionId"] as? String, "sig_1")
        let inner = try XCTUnwrap(obj["data"] as? [String: Any])
        XCTAssertEqual(inner["candidate"] as? String, "candidate:xyz")
        XCTAssertEqual(inner["sdpMid"] as? String, "0")
        XCTAssertEqual(inner["sdpMLineIndex"] as? Int, 1)
    }

    func test_close_shape() throws {
        let data = try XCTUnwrap(SignalingProtocol.close(sessionId: "sig_1"))
        let obj = try decode(data)
        XCTAssertEqual(obj["type"] as? String, "close")
        XCTAssertEqual(obj["sessionId"] as? String, "sig_1")
    }

    // MARK: - Helpers

    private func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
