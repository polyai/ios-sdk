import XCTest
@testable import PolyMessaging

/// Regression tests for the user-message echo dedup path. The audit flagged
/// `firstIndex(where: text == ...)` as broken for burst-identical sends
/// (P0-MSG-1), but investigation showed the existing `firstIndex + remove(at:)`
/// pattern already produces FIFO ordering because each match removes the
/// matched entry. These tests pin that behaviour so a future refactor
/// can't regress it.
final class ChatServiceDedupTests: XCTestCase {

    func testBurstIdenticalTextEchoesMatchInOrder() async {
        let service = ChatService(logger: NoopLogger())

        // Subscribe synchronously then finish()+drain (deterministic) — a
        // deferred Task + fixed sleep races the synchronous emits on a loaded
        // runner and intermittently misses .messageConfirmed events.
        let stream = service.eventStream.subscribe()

        // Two optimistic sends with identical text
        let prepared1 = await service.prepareUserMessage(text: "ok")
        let prepared2 = await service.prepareUserMessage(text: "ok")
        XCTAssertNotNil(prepared1)
        XCTAssertNotNil(prepared2)

        // Server echoes both, in order
        let echo1 = MessagingEvent.userMessage(
            makeEnvelope(id: "s1"),
            UserMessageEchoPayload(messageId: "server_1", text: "ok")
        )
        let echo2 = MessagingEvent.userMessage(
            makeEnvelope(id: "s2"),
            UserMessageEchoPayload(messageId: "server_2", text: "ok")
        )
        _ = await service.handleMessage(echo1)
        _ = await service.handleMessage(echo2)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let confirmed = emitted.compactMap { event -> (String, String)? in
            if case .messageConfirmed(let draft, let server) = event {
                return (draft, server)
            }
            return nil
        }

        // Both echoes should resolve to messageConfirmed (not pass through
        // as fresh .userMessage events).
        XCTAssertEqual(confirmed.count, 2)

        // FIFO ordering: first echo confirms first draft, second confirms
        // second draft.
        XCTAssertEqual(confirmed[0].0, prepared1?.draftId)
        XCTAssertEqual(confirmed[0].1, "server_1")
        XCTAssertEqual(confirmed[1].0, prepared2?.draftId)
        XCTAssertEqual(confirmed[1].1, "server_2")
    }

    func testInterleavedTextsMatchByText() async {
        let service = ChatService(logger: NoopLogger())

        let stream = service.eventStream.subscribe()

        let prepHi = await service.prepareUserMessage(text: "hi")
        let prepOk = await service.prepareUserMessage(text: "ok")
        let prepHi2 = await service.prepareUserMessage(text: "hi")

        // Server echoes in a different order: ok, hi, hi
        _ = await service.handleMessage(.userMessage(
            makeEnvelope(id: "s1"),
            UserMessageEchoPayload(messageId: "m_ok", text: "ok")
        ))
        _ = await service.handleMessage(.userMessage(
            makeEnvelope(id: "s2"),
            UserMessageEchoPayload(messageId: "m_hi_1", text: "hi")
        ))
        _ = await service.handleMessage(.userMessage(
            makeEnvelope(id: "s3"),
            UserMessageEchoPayload(messageId: "m_hi_2", text: "hi")
        ))
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let confirmedIds = emitted.compactMap { event -> String? in
            if case .messageConfirmed(let draft, _) = event {
                return draft
            }
            return nil
        }

        // Each optimistic draft was confirmed exactly once.
        XCTAssertEqual(Set(confirmedIds).count, 3)
        XCTAssertTrue(confirmedIds.contains(prepHi!.draftId))
        XCTAssertTrue(confirmedIds.contains(prepOk!.draftId))
        XCTAssertTrue(confirmedIds.contains(prepHi2!.draftId))
    }
}
