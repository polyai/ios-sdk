// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Robustness / stress probes for `WireDecoder` against malformed wire payloads.
/// Every assertion captures the decoder's CURRENT behaviour (no source changes).
final class StressMalformedWireTests: XCTestCase {

    // MARK: - Null payload on a batch frame

    func testDecodeBatchWithNullPayloadDoesNotCrash() {
        // `dict("payload")` is an `as? WireJSON` cast that fails on NSNull, so the batch guard bails.
        let json = """
        {
            "type": "EVENT_TYPE_EVENT_BATCH",
            "payload": null
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 0, "Null batch payload must drop to exactly zero events, not crash")
    }

    // MARK: - Empty id + nil sequence on a single event

    func testDecodeEventWithEmptyIdAndNilSequenceHandled() {
        // Empty (non-nil) id still passes the id/timestamp presence guard.
        let json = """
        {
            "id": "",
            "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_POLY_AGENT_MESSAGE",
            "payload": { "message_id": "m1", "text": "Hi" }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 1, "Empty id with valid timestamp should still decode")

        guard case .agentMessage(let env, let payload) = events.first else {
            XCTFail("Expected agentMessage"); return
        }
        XCTAssertEqual(env.id, "", "Empty wire id is preserved verbatim")
        XCTAssertNil(env.sequence, "Missing sequence stays nil")
        XCTAssertEqual(payload.text, "Hi")
    }

    // MARK: - Wrong-case type string

    func testDecodeLowercaseTypeStringIgnored() {
        // Type matching is case-sensitive: lowercase doesn't match the `EVENT_TYPE_*` raw values.
        let json = """
        {
            "id": "evt_lc",
            "sequence": 1,
            "timestamp": "2026-05-07T12:00:00Z",
            "type": "event_type_poly_agent_message",
            "payload": { "message_id": "m1", "text": "Hi" }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(events.count, 0, "Wrong-case event type must not match a known type; drops to exactly zero events")
    }

    // MARK: - Primitive element inside a batch's events array

    /// CHANGE-DETECTOR pinning CURRENT (suspected-buggy) behaviour: `array("events")` is an
    /// `as? [WireJSON]` cast, so one non-object element fails the whole cast and drops the ENTIRE
    /// batch to 0 events. There is no per-element tolerance today; bump expected to 2 if that lands.
    func testDecodeBatchWithPrimitiveInEventsArray_pinsCurrentWholeBatchDrop() {
        let json = """
        {
            "type": "EVENT_TYPE_EVENT_BATCH",
            "payload": {
                "events": [
                    {
                        "id": "evt_b1",
                        "sequence": 1,
                        "timestamp": "2026-05-07T12:00:00Z",
                        "type": "EVENT_TYPE_POLY_AGENT_MESSAGE",
                        "payload": { "message_id": "m1", "text": "Hi" }
                    },
                    "i am not an object",
                    {
                        "id": "evt_b2",
                        "sequence": 2,
                        "timestamp": "2026-05-07T12:00:01Z",
                        "type": "EVENT_TYPE_USER_MESSAGE",
                        "payload": { "message_id": "m2", "text": "Hello" }
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        XCTAssertEqual(
            events.count, 0,
            "Pins CURRENT behaviour: a primitive in the events array fails the [WireJSON] cast and drops the WHOLE batch (expected 2 once per-element tolerance is added)"
        )
    }
}