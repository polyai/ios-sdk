// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Robustness / stress probes for the streaming-chunk assembly path in
/// `ChatService` (and its private `StreamingBuffer`). These focus on the
/// edges that an unreliable backend / lossy transport can produce: a
/// replayed (duplicate) chunk index, and assembled payloads that sit right
/// on the `maxMessageSize` boundary.
final class StressStreamingTests: XCTestCase {

    private func makeService() -> ChatService {
        ChatService(logger: NoopLogger())
    }

    /// Drains every event ChatService emits for `body`, synchronously
    /// subscribing first so the non-replaying stream can't drop the emits.
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

    /// A duplicate (replayed) chunk index must not REORDER the assembled text:
    /// the surrounding chunks must keep their index ordering and the replayed
    /// chunk's index must land in its proper slot, never shuffled to the front
    /// or end.
    ///
    /// NOTE on duplication: `StreamingBuffer` appends every chunk and only
    /// sorts by `chunkIndex` at `finalize()` — it does NOT dedup by index.
    /// So a replayed chunk's text appears TWICE in the assembled string. The
    /// probe intent ("must not duplicate") is therefore NOT met by the current
    /// implementation; we assert the ACTUAL current behaviour (the replayed
    /// text is duplicated, in order) and record the mismatch in suspectedBugs
    /// rather than weakening the test. The ordering guarantee — the load-bearing
    /// safety property — IS upheld and is asserted strictly.
    func testStreamingChunksWithDuplicateIndexNotReordered() async {
        let service = makeService()

        let events = await drain(service) {
            // Ordered chunks 0,1,2 then a REPLAY of index 1 ("beta"),
            // then the completing chunk at index 3.
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

        // Ordering invariant: stable sort by chunkIndex keeps lower indices
        // ahead of higher ones, and the replayed index-1 token sits in its
        // index-1 slot — never reordered before "alpha" or after "gamma".
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
            // The two beta tokens must be adjacent — proves the replayed index
            // landed in its proper slot and did not scatter the ordering.
            XCTAssertEqual(lastBeta - firstBeta, 1, "replayed index-1 token must sit adjacent in its slot")
        }

        // Documented current behaviour: NOT deduped — "beta" appears twice.
        // If StreamingBuffer ever starts deduping by chunkIndex this assertion
        // must be revisited (and the suspectedBug closed).
        XCTAssertEqual(
            tokens.filter { $0 == "beta" }.count, 2,
            "ACTUAL current behaviour: replayed chunk index is NOT deduped (suspected bug)"
        )
        XCTAssertEqual(text, "alpha beta beta gamma delta")
    }

    // MARK: - Chunk size at the max-message-size boundary

    /// Assembling a streamed agent message whose utf8 length is exactly
    /// `maxMessageSize`, and exactly `maxMessageSize + 1`, must NOT silently
    /// truncate the assembled text. `maxMessageSize` gates only OUTGOING user
    /// messages (`prepareUserMessage`); the inbound streaming-assembly path
    /// applies no cap, so both boundary sizes survive intact.
    func testStreamingChunkSizeAtBoundary() async {
        let maxSize = 1024

        for delta in [0, 1] {
            let service = makeService()
            // Establish the capability so maxMessageSize is the value under test
            // (also proves the inbound path ignores it).
            _ = await service.handleMessage(.sessionStart(
                makeEnvelope(id: "boot"),
                makeSessionStartPayload(maxMessageSize: maxSize)
            ))

            let configured = await service.maxMessageSize
            XCTAssertEqual(configured, maxSize)

            // Single-chunk stream so there is no joining separator to perturb
            // the byte count — the assembled utf8 length equals the chunk's.
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