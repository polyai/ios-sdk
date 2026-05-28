// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class WireEncoderTests: XCTestCase {

    private func decodeJSON(_ data: Data) -> WireJSON? {
        try? JSONSerialization.jsonObject(with: data) as? WireJSON
    }

    func testEncodeUserMessage() {
        let data = WireEncoder.encode(.userMessage(text: "Hello"))
        XCTAssertNotNil(data)

        let json = decodeJSON(data!)!
        XCTAssertEqual(json.string("type"), "EVENT_TYPE_USER_MESSAGE")

        let payload = json.dict("payload")
        XCTAssertEqual(payload?.string("text"), "Hello")
    }

    func testEncodeUserEndConversation() {
        let data = WireEncoder.encode(.userEndConversation)
        XCTAssertNotNil(data)

        let json = decodeJSON(data!)!
        // Collapses to USER_END_SESSION on V2 (matches web).
        XCTAssertEqual(json.string("type"), "EVENT_TYPE_USER_END_SESSION")
        XCTAssertNotNil(json.dict("payload"))
    }

    func testEncodeRequestPolyAgentJoin() {
        let data = WireEncoder.encode(.requestPolyAgentJoin)
        XCTAssertNotNil(data)

        let json = decodeJSON(data!)!
        XCTAssertEqual(json.string("type"), "EVENT_TYPE_REQUEST_POLY_AGENT_JOIN")
        XCTAssertNotNil(json.dict("payload"))
    }

    func testEncodeHeartbeat() {
        // Backend `poly_agent_processor.go:341` touchSession's + echoes
        // heartbeats, so iOS sends them rather than silently dropping. Empty
        // payload object per `HeartbeatPayload {}` in events.proto.
        let data = WireEncoder.encode(.heartbeat)
        XCTAssertNotNil(data)
        let json = decodeJSON(data!)!
        XCTAssertEqual(json.string("type"), "EVENT_TYPE_HEARTBEAT")
        XCTAssertNotNil(json.dict("payload"))
    }

    func testEncodeUserTypingStarted() {
        let data = WireEncoder.encode(.userTyping(.started))
        XCTAssertNotNil(data)
        let json = decodeJSON(data!)!
        XCTAssertEqual(json.string("type"), "EVENT_TYPE_USER_TYPING")
        let payload = json.dict("payload")
        XCTAssertEqual(payload?.string("state"), "TYPING_STATE_STARTED")
    }

    func testEncodeUserTypingStopped() {
        let data = WireEncoder.encode(.userTyping(.stopped))
        XCTAssertNotNil(data)
        let json = decodeJSON(data!)!
        XCTAssertEqual(json.string("type"), "EVENT_TYPE_USER_TYPING")
        let payload = json.dict("payload")
        XCTAssertEqual(payload?.string("state"), "TYPING_STATE_STOPPED")
    }

    func testEncodeUserLeft() {
        let data = WireEncoder.encode(.userLeft)
        XCTAssertNotNil(data)

        let json = decodeJSON(data!)!
        // Collapses to USER_END_SESSION on V2 (matches web).
        XCTAssertEqual(json.string("type"), "EVENT_TYPE_USER_END_SESSION")
        XCTAssertNotNil(json.dict("payload"))
    }

    func testEncodedJSONIsValidUTF8() {
        let data = WireEncoder.encode(.userMessage(text: "test 🎉"))!
        let string = String(data: data, encoding: .utf8)
        XCTAssertNotNil(string)
        XCTAssertTrue(string!.contains("test"))
    }
}
