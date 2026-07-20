// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Stress probes for `ChatService` streaming-chunk assembly: replayed chunk
/// index and payloads on the `maxMessageSize` boundary.
final class StressStreamingTests: XCTestCase {

    private func makeService() -> ChatService {
        ChatService(logger: NoopLogger())
    }

    /// Subscribes before running `body` so the non-replaying stream can't drop emits.
    private func drain(
        _ service: ChatService,
        _ body: () async -> Void
    ) async -> [MessagingEvent] {
        let stream = service.eventStream.subscribe()
        await body()
        service.eventStream.finish()
        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }
        return emitted
    }

    private func assembledMessages(_ events: [MessagingEvent]) -> [AgentMessagePayload] {
        events.compactMap {
            if case .agentMessage(_, let payload) = $0 { return payload }
            return nil
        }
    }

    // MARK: - Duplicate / replayed chunk index

    /// A replayed chunk index must not reorder the assembled text. Documents
    /// CURRENT (suspected-buggy) behaviour: `StreamingBuffer` only sorts by
    /// `chunkIndex` at `finalize()` and does NOT dedup, so the replayed text
    /// appears twice; the ordering guarantee is upheld and asserted strictly.
    func testStreamingChunksWithDuplicateIndexNotReordered() async {
        let service = makeService()

        let events = await drain(service) {
            _ = await service.handleMessage(.agentMessageChunk(
                makeEnvelope(id: "e0"),
                makeChunkPayload(messageId: "m1", chunkIndex: 0, text: "alpha")
            ))
            _ = await service.handleMessage(.agentMessageChunk(
                makeEnvelope(id: "e1"),
                makeChunkPayload(messageId: "m1", chunkIndex: 1, text: "beta")
            ))
            _ = await service.handleMessage(.agentMessageChunk(
                makeEnvelope(id: "e2"),
                makeChunkPayload(messageId: "m1", chunkIndex: 2, text: "gamma")
            ))
            // Replay of index 1 (e.g. transport redelivery after a reconnect).
            _ = await service.handleMessage(.agentMessageChunk(
                makeEnvelope(id: "e1_replay"),
                makeChunkPayload(messageId: "m1", chunkIndex: 1, text: "beta")
            ))
            _ = await service.handleMessage(.agentMessageChunk(
                makeEnvelope(id: "e3"),
                makeChunkPayload(messageId: "m1", chunkIndex: 3, isComplete: true, text: "delta")
            ))
        }

        let assembled = assembledMessages(events)
        XCTAssertEqual(assembled.count, 1, "Exactly one assembled message expected")
        guard let text = assembled.first?.text else {
            return XCTFail("No assembled agent message")
        }

        let tokens = text.split(separator: " ").map(String.init)

        // Ordering invariant: stable sort by chunkIndex keeps lower indices ahead.
        let firstBeta = tokens.firstIndex(of: "beta")
        let lastBeta = tokens.lastIndex(of: "beta")
        let alpha = tokens.firstIndex(of: "alpha")
        let gamma = tokens.firstIndex(of: "gamma")
        let delta = tokens.firstIndex(of: "delta")

        XCTAssertNotNil(alpha)
        XCTAssertNotNil(gamma)
        XCTAssertNotNil(delta)
        XCTAssertNotNil(firstBeta)
        XCTAssertNotNil(lastBeta)

        if let alpha, let firstBeta, let lastBeta, let gamma, let delta {
            XCTAssertLessThan(alpha, firstBeta, "alpha (idx0) must precede beta (idx1)")
            XCTAssertLessThan(lastBeta, gamma, "all beta (idx1) must precede gamma (idx2)")
            XCTAssertLessThan(gamma, delta, "gamma (idx2) must precede delta (idx3)")
            // Two beta tokens adjacent proves the replayed index landed in its slot.
            XCTAssertEqual(lastBeta - firstBeta, 1, "replayed index-1 token must sit adjacent in its slot")
        }

        // Documents CURRENT behaviour: NOT deduped — "beta" appears twice.
        // Revisit if StreamingBuffer ever dedups by chunkIndex.
        XCTAssertEqual(
            tokens.filter { $0 == "beta" }.count, 2,
            "ACTUAL current behaviour: replayed chunk index is NOT deduped (suspected bug)"
        )
        XCTAssertEqual(text, "alpha beta beta gamma delta")
    }

    // MARK: - Chunk size at the max-message-size boundary

    /// Assembling a stream at exactly `maxMessageSize` (and +1) must not truncate:
    /// `maxMessageSize` gates only OUTGOING user messages, not inbound assembly.
    func testStreamingChunkSizeAtBoundary() async {
        let maxSize = 1024

        for delta in [0, 1] {
            let service = makeService()
            _ = await service.handleMessage(.sessionStart(
                makeEnvelope(id: "boot"),
                makeSessionStartPayload(maxMessageSize: maxSize)
            ))

            let configured = await service.maxMessageSize
            XCTAssertEqual(configured, maxSize)

            // Single-chunk stream so no joining separator perturbs the byte count.
            let length = maxSize + delta
            let body = String(repeating: "x", count: length)
            XCTAssertEqual(body.utf8.count, length, "fixture must be exactly \(length) bytes")

            let events = await drain(service) {
                _ = await service.handleMessage(.agentMessageChunk(
                    makeEnvelope(id: "c0"),
                    AgentMessageChunkPayload(
                        messageId: "m_big", chunkIndex: 0, isComplete: true,
                        text: body, attachments: [], responseSuggestions: []
                    )
                ))
            }

            let assembled = assembledMessages(events)
            XCTAssertEqual(assembled.count, 1, "boundary delta=\(delta): one assembled message expected")
            XCTAssertEqual(
                assembled.first?.text.utf8.count, length,
                "boundary delta=\(delta): assembled utf8 length must be preserved, no truncation"
            )
            XCTAssertEqual(
                assembled.first?.text, body,
                "boundary delta=\(delta): assembled text must be byte-identical to the chunk"
            )
        }
    }
}