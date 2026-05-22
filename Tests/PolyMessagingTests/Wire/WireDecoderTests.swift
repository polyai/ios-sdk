import XCTest
@testable import PolyMessaging

final class WireDecoderTests: XCTestCase {

    // MARK: - Session events

    func testDecodeSessionStart() {
        let json = """
        {
            "id": "evt_001",
            "sequence": 1,
            "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_SESSION_START",
            "payload": {
                "capabilities": {
                    "streaming": true,
                    "max_message_size_bytes": 65536,
                    "heartbeat_interval_seconds": 30,
                    "max_reconnect_attempts": 10
                }
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 1)

        guard case .sessionStart(let env, let payload) = events.first else {
            XCTFail("Expected sessionStart"); return
        }
        XCTAssertEqual(env.id, "evt_001")
        XCTAssertEqual(env.sequence, 1)
        XCTAssertTrue(payload.capabilities.streaming)
        XCTAssertEqual(payload.capabilities.maxMessageSize, 65536)
        XCTAssertEqual(payload.capabilities.heartbeatIntervalSeconds, 30)
        XCTAssertEqual(payload.capabilities.maxReconnectAttempts, 10)
    }

    func testDecodeSessionEnd() {
        let json = """
        {
            "id": "evt_002",
            "sequence": 50,
            "timestamp": "2026-05-07T12:30:00Z",
            "type": "EVENT_TYPE_SESSION_END",
            "payload": { "reason": "agent_ended" }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        guard case .sessionEnd(_, let payload) = events.first else {
            XCTFail("Expected sessionEnd"); return
        }
        XCTAssertEqual(payload.reason, "agent_ended")
    }

    // MARK: - Agent messages

    func testDecodeAgentMessage() {
        let json = """
        {
            "id": "evt_010",
            "sequence": 10,
            "timestamp": "2026-05-07T12:01:00Z",
            "type": "EVENT_TYPE_POLY_AGENT_MESSAGE",
            "payload": {
                "message_id": "msg_abc",
                "text": "Hello there!",
                "agent_name": "Poly",
                "attachments": [
                    {
                        "content_type": "ATTACHMENT_CONTENT_TYPE_IMAGE",
                        "content_url": "https://example.com/img.png",
                        "title": "Screenshot"
                    }
                ],
                "response_suggestions": [
                    { "message_text": "Yes", "payload": "yes_intent" }
                ]
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        guard case .agentMessage(_, let p) = events.first else {
            XCTFail("Expected agentMessage"); return
        }
        XCTAssertEqual(p.messageId, "msg_abc")
        XCTAssertEqual(p.text, "Hello there!")
        XCTAssertEqual(p.agentName, "Poly")
        XCTAssertEqual(p.attachments.count, 1)
        XCTAssertEqual(p.attachments.first?.contentType, .image)
        XCTAssertEqual(p.responseSuggestions.count, 1)
        XCTAssertEqual(p.responseSuggestions.first?.messageText, "Yes")
    }

    func testDecodeAgentMessageChunk() {
        let json = """
        {
            "id": "evt_011",
            "sequence": 11,
            "timestamp": "2026-05-07T12:01:01Z",
            "type": "EVENT_TYPE_POLY_AGENT_MESSAGE_CHUNK",
            "payload": {
                "message_id": "msg_chunk_1",
                "chunk_index": 2,
                "is_complete": false,
                "text": "partial response"
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        guard case .agentMessageChunk(_, let p) = events.first else {
            XCTFail("Expected agentMessageChunk"); return
        }
        XCTAssertEqual(p.messageId, "msg_chunk_1")
        XCTAssertEqual(p.chunkIndex, 2)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.text, "partial response")
    }

    // MARK: - Live agent typing (state)

    func testDecodeLiveAgentTypingStarted() {
        let json = """
        {
            "id": "evt_t1",
            "type": "EVENT_TYPE_LIVE_AGENT_TYPING",
            "timestamp": "2026-05-07T12:00:00Z",
            "payload": { "state": "TYPING_STATE_STARTED", "agent_id": "agent-42" }
        }
        """.data(using: .utf8)!

        guard case .liveAgentTyping(_, let p) = WireDecoder.decode(json).first else {
            XCTFail("Expected liveAgentTyping"); return
        }
        XCTAssertEqual(p.state, .started)
        XCTAssertEqual(p.agentId, "agent-42")
    }

    func testDecodeLiveAgentTypingStopped() {
        let json = """
        {
            "id": "evt_t2",
            "type": "EVENT_TYPE_LIVE_AGENT_TYPING",
            "timestamp": "2026-05-07T12:00:00Z",
            "payload": { "state": "TYPING_STATE_STOPPED", "agent_id": "agent-42" }
        }
        """.data(using: .utf8)!

        guard case .liveAgentTyping(_, let p) = WireDecoder.decode(json).first else {
            XCTFail("Expected liveAgentTyping"); return
        }
        XCTAssertEqual(p.state, .stopped)
    }

    func testDecodeLiveAgentTypingDefaultsToStartedWhenStateMissing() {
        // Forward-compat: legacy senders that omit `state` still light up the
        // indicator instead of silently rendering nothing.
        let json = """
        {
            "id": "evt_t3",
            "type": "EVENT_TYPE_LIVE_AGENT_TYPING",
            "timestamp": "2026-05-07T12:00:00Z",
            "payload": { "agent_id": "agent-42" }
        }
        """.data(using: .utf8)!

        guard case .liveAgentTyping(_, let p) = WireDecoder.decode(json).first else {
            XCTFail("Expected liveAgentTyping"); return
        }
        XCTAssertEqual(p.state, .started)
    }

    // MARK: - Batch

    func testDecodeEventBatch() {
        let json = """
        {
            "type": "EVENT_TYPE_EVENT_BATCH",
            "payload": {
                "events": [
                    {
                        "id": "evt_b1",
                        "sequence": 1,
                        "timestamp": "2026-05-07T12:00:00Z",
                        "type": "EVENT_TYPE_SESSION_START",
                        "payload": { "capabilities": { "streaming": true, "max_message_size_bytes": 65536 } }
                    },
                    {
                        "id": "evt_b2",
                        "sequence": 2,
                        "timestamp": "2026-05-07T12:00:01Z",
                        "type": "EVENT_TYPE_POLY_AGENT_MESSAGE",
                        "payload": { "message_id": "m1", "text": "Hi" }
                    },
                    {
                        "id": "evt_b3",
                        "sequence": 3,
                        "timestamp": "2026-05-07T12:00:02Z",
                        "type": "EVENT_TYPE_USER_MESSAGE",
                        "payload": { "message_id": "m2", "text": "Hello" }
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 3)

        if case .sessionStart = events[0] {} else { XCTFail("Expected sessionStart at 0") }
        if case .agentMessage = events[1] {} else { XCTFail("Expected agentMessage at 1") }
        if case .userMessage = events[2] {} else { XCTFail("Expected userMessage at 2") }
    }

    func testDecodeEventBatchSortsBySequence() {
        // Events arrive out of order (sequence 3, 1, 2) — should be reordered to 1, 2, 3.
        let json = """
        {
            "type": "EVENT_TYPE_EVENT_BATCH",
            "payload": {
                "events": [
                    {
                        "id": "evt_b3",
                        "sequence": 3,
                        "timestamp": "2026-05-07T12:00:02Z",
                        "type": "EVENT_TYPE_USER_MESSAGE",
                        "payload": { "message_id": "m2", "text": "Hello" }
                    },
                    {
                        "id": "evt_b1",
                        "sequence": 1,
                        "timestamp": "2026-05-07T12:00:00Z",
                        "type": "EVENT_TYPE_SESSION_START",
                        "payload": { "capabilities": { "streaming": true } }
                    },
                    {
                        "id": "evt_b2",
                        "sequence": 2,
                        "timestamp": "2026-05-07T12:00:01Z",
                        "type": "EVENT_TYPE_POLY_AGENT_MESSAGE",
                        "payload": { "message_id": "m1", "text": "Hi" }
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 3)

        XCTAssertEqual(events[0].envelope?.sequence, 1)
        XCTAssertEqual(events[1].envelope?.sequence, 2)
        XCTAssertEqual(events[2].envelope?.sequence, 3)

        if case .sessionStart = events[0] {} else { XCTFail("Expected sessionStart at 0") }
        if case .agentMessage = events[1] {} else { XCTFail("Expected agentMessage at 1") }
        if case .userMessage = events[2] {} else { XCTFail("Expected userMessage at 2") }
    }

    func testDecodeEventBatchNilSequenceAtEnd() {
        // Events without a sequence should be placed after sequenced events,
        // preserving their relative order among themselves.
        let json = """
        {
            "type": "EVENT_TYPE_EVENT_BATCH",
            "payload": {
                "events": [
                    {
                        "id": "evt_no_seq",
                        "timestamp": "2026-05-07T12:00:00Z",
                        "type": "EVENT_TYPE_SYSTEM_MESSAGE",
                        "payload": { "message": "info", "level": "SYSTEM_MESSAGE_LEVEL_INFO" }
                    },
                    {
                        "id": "evt_seq2",
                        "sequence": 2,
                        "timestamp": "2026-05-07T12:00:01Z",
                        "type": "EVENT_TYPE_POLY_AGENT_MESSAGE",
                        "payload": { "message_id": "m1", "text": "Hi" }
                    },
                    {
                        "id": "evt_seq1",
                        "sequence": 1,
                        "timestamp": "2026-05-07T12:00:00Z",
                        "type": "EVENT_TYPE_SESSION_START",
                        "payload": { "capabilities": { "streaming": false } }
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 3)

        // Sequenced events first (sorted), then nil-sequence at the end.
        XCTAssertEqual(events[0].envelope?.id, "evt_seq1")
        XCTAssertEqual(events[1].envelope?.id, "evt_seq2")
        XCTAssertEqual(events[2].envelope?.id, "evt_no_seq")
        XCTAssertNil(events[2].envelope?.sequence)
    }

    // MARK: - Edge cases

    func testUnknownTypeReturnsEmpty() {
        let json = """
        {
            "id": "evt_unk",
            "sequence": 99,
            "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_FUTURE_THING",
            "payload": {}
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertTrue(events.isEmpty)
    }

    func testMalformedJSONReturnsEmpty() {
        let data = "not json at all".data(using: .utf8)!
        let events = WireDecoder.decode(data)
        XCTAssertTrue(events.isEmpty)
    }

    func testNoTypeFieldReturnsEmpty() {
        let json = """
        { "id": "evt_notype", "payload": {} }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertTrue(events.isEmpty)
    }

    func testHeartbeatDecodesWithoutIdOrTimestamp() {
        let json = """
        { "type": "EVENT_TYPE_HEARTBEAT" }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 1)
        if case .heartbeat = events.first {} else { XCTFail("Expected heartbeat") }
    }

    // MARK: - Poly agent joined

    func testDecodePolyAgentJoinedWithCanonicalAvatarUrl() {
        let json = """
        {
            "id": "evt_aj",
            "sequence": 5,
            "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_POLY_AGENT_JOINED",
            "payload": {
                "agent_name": "Ada",
                "agent_avatar_url": "https://example.com/ada.png"
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        guard case .agentJoined(_, let p) = events.first else {
            XCTFail("Expected agentJoined"); return
        }
        XCTAssertEqual(p.agentName, "Ada")
        XCTAssertEqual(p.avatarUrl?.absoluteString, "https://example.com/ada.png")
    }

    func testDecodePolyAgentJoinedFallsBackToAvatarUrl() {
        let json = """
        {
            "id": "evt_aj2",
            "sequence": 6,
            "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_POLY_AGENT_JOINED",
            "payload": {
                "agent_name": "Ada",
                "avatar_url": "https://example.com/ada-legacy.png"
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        guard case .agentJoined(_, let p) = events.first else {
            XCTFail("Expected agentJoined"); return
        }
        XCTAssertEqual(p.avatarUrl?.absoluteString, "https://example.com/ada-legacy.png")
    }

    // MARK: - Live agent

    func testDecodeLiveAgentJoinedWithNestedAgent() {
        let json = """
        {
            "id": "evt_la",
            "sequence": 20,
            "timestamp": "2026-05-07T12:10:00Z",
            "type": "EVENT_TYPE_LIVE_AGENT_JOINED",
            "payload": {
                "agent": {
                    "name": "Sarah",
                    "avatar_url": "https://example.com/avatar.png"
                }
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        guard case .liveAgentJoined(_, let p) = events.first else {
            XCTFail("Expected liveAgentJoined"); return
        }
        XCTAssertEqual(p.agentName, "Sarah")
        XCTAssertEqual(p.avatarUrl?.absoluteString, "https://example.com/avatar.png")
    }

    // MARK: - System

    func testDecodeSystemMessage() {
        let json = """
        {
            "id": "evt_sys",
            "sequence": 30,
            "timestamp": "2026-05-07T12:15:00Z",
            "type": "EVENT_TYPE_SYSTEM_MESSAGE",
            "payload": {
                "message": "Something went wrong",
                "level": "SYSTEM_MESSAGE_LEVEL_ERROR"
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        guard case .systemMessage(_, let p) = events.first else {
            XCTFail("Expected systemMessage"); return
        }
        XCTAssertEqual(p.message, "Something went wrong")
        XCTAssertEqual(p.level, .error)
    }
}
