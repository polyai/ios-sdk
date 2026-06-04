// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress / robustness coverage for the user-message echo dedup path under
/// burst load with out-of-order server echoes.
///
/// The production echo matcher (`handleUserMessageEcho`) prefers the
/// `local_id` metadata carried on the echo envelope and only falls back to
/// text matching when that is absent. `prepareUserMessage` does NOT surface
/// the internally-generated `clientEventId`, so a test cannot reconstruct the
/// `local_id` to drive the metadata path. These probes therefore exercise the
/// realistic backend-without-local_id case (text fallback), which is exactly
/// where burst-identical sends are most fragile.
final class StressDedupTests: XCTestCase {

    /// 3x send("ok") then deliver the server echoes in REVERSE order.
    ///
    /// With identical text and no `local_id`, the matcher resolves each echo
    /// via `firstIndex(where: text == ...) + remove(at:)`. That yields strict
    /// FIFO consumption of the pending drafts: the i-th echo to ARRIVE confirms
    /// the i-th draft that was QUEUED. We pin that current behaviour:
    /// - every echo produces a `.messageConfirmed` (none leak as `.userMessage`)
    /// - each of the 3 drafts is confirmed exactly once (no dups, no orphans)
    /// - the draft<->server_id pairing follows arrival order, not echo label.
    func testBurstIdenticalSendsWithOutOfOrderEchoes() async {
        let service = ChatService(logger: NoopLogger())

        // Subscribe synchronously, then finish()+drain after the synchronous
        // emits — mirrors ChatServiceDedupTests to avoid racing emits.
        let stream = service.eventStream.subscribe()

        let prepared1 = await service.prepareUserMessage(text: "ok")
        let prepared2 = await service.prepareUserMessage(text: "ok")
        let prepared3 = await service.prepareUserMessage(text: "ok")
        XCTAssertNotNil(prepared1)
        XCTAssertNotNil(prepared2)
        XCTAssertNotNil(prepared3)

        // Server echoes arrive in REVERSE order of how the drafts were queued.
        // No local_id metadata -> text-fallback matching.
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

        // No echo should have leaked through as a fresh inbound user message —
        // each one was matched against a pending draft.
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

        // Exactly three confirmations, one per send. No duplicates, no orphans.
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

        // Every server_id we sent was consumed exactly once.
        let confirmedServerIds = Set(confirmed.map(\.server))
        XCTAssertEqual(
            confirmedServerIds, Set(["server_1", "server_2", "server_3"]),
            "every echoed server_id maps onto exactly one confirmation"
        )

        // Pin the FIFO-by-arrival pairing that the current matcher produces.
        // Echoes ARRIVED in order [server_3, server_2, server_1]; drafts were
        // QUEUED in order [d1, d2, d3]. firstIndex+remove pairs arrival #1 with
        // d1, arrival #2 with d2, arrival #3 with d3.
        XCTAssertEqual(confirmed[0].draft, prepared1!.draftId)
        XCTAssertEqual(confirmed[0].server, "server_3")
        XCTAssertEqual(confirmed[1].draft, prepared2!.draftId)
        XCTAssertEqual(confirmed[1].server, "server_2")
        XCTAssertEqual(confirmed[2].draft, prepared3!.draftId)
        XCTAssertEqual(confirmed[2].server, "server_1")
    }
}