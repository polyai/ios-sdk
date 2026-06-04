// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Robustness / stress probes for `WireDecoder` against malformed wire payloads.
/// Every assertion captures the decoder's CURRENT behaviour (no source changes).
final class StressMalformedWireTests: XCTestCase {

    // MARK: - Null payload on a batch frame

    func testDecodeBatchWithNullPayloadDoesNotCrash() {
        // An event-batch frame whose `payload` is JSON null. `dict("payload")`
        // does an `as? WireJSON` cast which fails on NSNull, so the batch guard
        // bails and the frame is dropped to an empty result — no crash.
        let json = """
        {
            "type": "EVENT_TYPE_EVENT_BATCH",
            "payload": null
        }
        """.data(using: .utf8)!

        let events = WireDecoder.decode(json)
        // Concrete outcome: the batch guard (`dict("payload")` is an `as? WireJSON`
        // cast that returns nil for NSNull) bails, so the frame decodes to EXACTLY
        // zero events — not "some" events, and not a crash. Assert the precise
        // count rather than `isEmpty` (which would also pass on any single decoded
        // event slipping through, hiding a regression).
        XCTAssertEqual(events.count, 0, "Null batch payload must drop to exactly zero events, not crash")
    }

    // MARK: - Empty id + nil sequence on a single event

    func testDecodeEventWithEmptyIdAndNilSequenceHandled() {
        // `id` is the empty string (non-nil, so the id/timestamp presence guard
        // still passes) and `sequence` is absent. The event decodes; the
        // envelope carries an empty id and a nil sequence.
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
        // Event type matching is case-sensitive: a lowercase spelling does not
        // match the `EVENT_TYPE_*` raw values, so the event is treated as an
        // unknown type and dropped.
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

    /// CHANGE-DETECTOR — pins the CURRENT (suspected-buggy) behaviour.
    ///
    /// The events array mixes valid event objects with a bare primitive
    /// (a string). The decoder reads `events` via `array(_:)`, which is an
    /// `as? [WireJSON]` cast; a single non-object element makes the WHOLE
    /// cast fail, so `array("events")` is nil and the ENTIRE batch is dropped
    /// to zero events rather than skipping just the bad element.
    ///
    /// The probe's original intent was "the primitive is skipped, the two valid
    /// events survive" (expected count == 2). The decoder does NOT do per-element
    /// tolerance today — one primitive poisons the whole batch (actual count == 0).
    /// This test deliberately asserts the ACTUAL behaviour so it FAILS loudly the
    /// day `WireDecoder` gains per-element tolerance; update the expected count to
    /// 2 (and assert the two surviving events) when that bug is fixed.
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
        // CURRENT behaviour: whole batch dropped → exactly 0 events.
        // When per-element tolerance lands this becomes 2 (the two valid events);
        // assert the exact count so the change-detector trips precisely.
        XCTAssertEqual(
            events.count, 0,
            "Pins CURRENT behaviour: a primitive in the events array fails the [WireJSON] cast and drops the WHOLE batch (expected 2 once per-element tolerance is added)"
        )
    }
}