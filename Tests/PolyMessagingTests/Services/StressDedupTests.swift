// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Echo-dedup stress coverage. `prepareUserMessage` doesn't surface the
/// internal `clientEventId`, so tests can't reconstruct `local_id` and these
/// exercise the text-fallback matching path (no `local_id` metadata).
final class StressDedupTests: XCTestCase {

    /// Pins current behaviour: with identical text and no `local_id`, the
    /// matcher's `firstIndex(text==) + remove(at:)` confirms the i-th draft
    /// QUEUED with the i-th echo to ARRIVE (FIFO by arrival, not by echo label).
    func testBurstIdenticalSendsWithOutOfOrderEchoes() async {
        let service = ChatService(logger: NoopLogger())

        // Subscribe before emits, finish()+drain after — avoids racing emits.
        let stream = service.eventStream.subscribe()

        let prepared1 = await service.prepareUserMessage(text: "ok")
        let prepared2 = await service.prepareUserMessage(text: "ok")
        let prepared3 = await service.prepareUserMessage(text: "ok")
        XCTAssertNotNil(prepared1)
        XCTAssertNotNil(prepared2)
        XCTAssertNotNil(prepared3)

        // Echoes arrive in REVERSE queue order; no local_id -> text fallback.
        _ = await service.handleMessage(.userMessage(
            makeEnvelope(id: "s3"),
            UserMessageEchoPayload(messageId: "server_3", text: "ok")
        ))
        _ = await service.handleMessage(.userMessage(
            makeEnvelope(id: "s2"),
            UserMessageEchoPayload(messageId: "server_2", text: "ok")
        ))
        _ = await service.handleMessage(.userMessage(
            makeEnvelope(id: "s1"),
            UserMessageEchoPayload(messageId: "server_1", text: "ok")
        ))
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let leakedUserMessages = emitted.filter { event -> Bool in
            if case .userMessage = event { return true }
            return false
        }
        XCTAssertTrue(
            leakedUserMessages.isEmpty,
            "every echo should dedup into a confirmation, none should pass through as .userMessage"
        )

        let confirmed = emitted.compactMap { event -> (draft: String, server: String)? in
            if case .messageConfirmed(let draft, let server) = event {
                return (draft, server)
            }
            return nil
        }

        XCTAssertEqual(confirmed.count, 3, "exactly 3 confirmations expected")

        let confirmedDrafts = confirmed.map(\.draft)
        XCTAssertEqual(
            Set(confirmedDrafts).count, 3,
            "each of the 3 drafts confirmed exactly once (no duplicate draft ids)"
        )

        let expectedDrafts = Set([
            prepared1!.draftId, prepared2!.draftId, prepared3!.draftId,
        ])
        XCTAssertEqual(
            Set(confirmedDrafts), expectedDrafts,
            "the confirmed drafts are exactly the three we queued (no orphans)"
        )

        let confirmedServerIds = Set(confirmed.map(\.server))
        XCTAssertEqual(
            confirmedServerIds, Set(["server_1", "server_2", "server_3"]),
            "every echoed server_id maps onto exactly one confirmation"
        )

        // FIFO-by-arrival: arrival order [s3,s2,s1] pairs with queue order [d1,d2,d3].
        XCTAssertEqual(confirmed[0].draft, prepared1!.draftId)
        XCTAssertEqual(confirmed[0].server, "server_3")
        XCTAssertEqual(confirmed[1].draft, prepared2!.draftId)
        XCTAssertEqual(confirmed[1].server, "server_2")
        XCTAssertEqual(confirmed[2].draft, prepared3!.draftId)
        XCTAssertEqual(confirmed[2].server, "server_1")
    }
}