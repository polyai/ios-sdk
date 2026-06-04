// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Robustness / stress probes for oversized and content-only inbound frames.
final class StressInboundSizeTests: XCTestCase {

    private func makeService() -> ChatService {
        ChatService(logger: NoopLogger())
    }

    // MARK: - Oversized inbound text

    /// A very large agent text must be delivered through the decoder intact —
    /// the inbound path does not (and should not) truncate. The
    /// `max_message_size_bytes` capability is an *outbound* guard
    /// (`prepareUserMessage`), never applied to decoded inbound payloads.
    func testAgentMessageWithOversizedTextPassesThroughUntruncated() {
        // ~512 KiB of text — far larger than any UI bubble would normally hold.
        let bigText = String(repeating: "A", count: 512 * 1024)
        XCTAssertEqual(bigText.count, 524_288)

        let payloadJSON: [String: Any] = [
            "id": "evt_big",
            "sequence": 1,
            "timestamp": "2026-05-07T12:00:00Z",
            "type": "EVENT_TYPE_POLY_AGENT_MESSAGE",
            "payload": [
                "message_id": "msg_big",
                "text": bigText,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payloadJSON)

        let events = WireDecoder.decode(data)
        XCTAssertEqual(events.count, 1)

        guard case .agentMessage(let env, let p) = events.first else {
            XCTFail("Expected agentMessage"); return
        }
        XCTAssertEqual(env.id, "evt_big")
        XCTAssertEqual(p.messageId, "msg_big")
        // Byte-for-byte intact: same length and same content, no truncation.
        XCTAssertEqual(p.text.count, 524_288)
        XCTAssertEqual(p.text, bigText)
    }

    // MARK: - Content-only message (call actions, no text)

    /// An agent message that carries ONLY call actions (empty text, no
    /// attachments, no suggestions) still counts as content and must surface
    /// to the consumer. `ChatService.handleAgentMessage` treats a non-empty
    /// `chatCallActions` array as content (mirroring web `hasContent`), so the
    /// `.agentMessage` event is emitted rather than silently dropped.
    func testAgentMessageWithOnlyCallActionsEmitted() async {
        let service = makeService()

        let payload = AgentMessagePayload(
            messageId: "msg_calls",
            text: "",
            agentName: nil,
            avatarUrl: nil,
            attachments: [],
            responseSuggestions: [],
            chatCallActions: [
                ChatCallAction(title: "Call support", contactNumber: "+15551234567"),
            ],
            endConversation: false
        )
        let event = MessagingEvent.agentMessage(makeEnvelope(id: "evt_calls"), payload)

        // Subscribe synchronously, then handle + finish + drain to avoid the
        // deferred-Task attach race documented in ChatServiceTests.
        let stream = service.eventStream.subscribe()
        _ = await service.handleMessage(event)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await e in stream { emitted.append(e) }

        let agentMessages = emitted.compactMap { event -> AgentMessagePayload? in
            if case .agentMessage(_, let p) = event { return p }
            return nil
        }
        XCTAssertEqual(
            agentMessages.count, 1,
            "A call-actions-only agent message must surface (hasContent == true)"
        )
        let surfaced = agentMessages.first
        XCTAssertEqual(surfaced?.text, "")
        XCTAssertEqual(surfaced?.chatCallActions.count, 1)
        XCTAssertEqual(surfaced?.chatCallActions.first?.title, "Call support")
        XCTAssertEqual(surfaced?.chatCallActions.first?.contactNumber, "+15551234567")
    }
}
