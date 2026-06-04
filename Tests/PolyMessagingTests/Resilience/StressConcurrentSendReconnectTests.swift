// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Drives `ChatService`'s `waitForTransportOpen`/`retrySender` hooks directly (no
/// Coordinator) for deterministic timing. Invariant: a send caught in a reconnect
/// window always reaches a terminal outcome (confirmed or failed), never hung or dropped.
final class StressConcurrentSendReconnectTests: XCTestCase {

    private func makeStartedService() async -> ChatService {
        let service = ChatService(logger: NoopLogger())
        // SESSION_START flips `chatStarted = true` so prepareUserMessage enqueues.
        _ = await service.handleMessage(
            MessagingEvent.sessionStart(
                makeEnvelope(id: "evt_boot"), makeSessionStartPayload()
            )
        )
        return service
    }

    // MARK: -

    /// Every retry lands mid-reconnect (`waitForTransportOpen` keeps returning `false`,
    /// the socket never recovers so no USER_MESSAGE echo confirms the draft). Invariant:
    /// the draft fails exactly once after the full retry budget (`maxRetries == 3`) is
    /// spent, each retry having consulted the wait hook first — never hung or dropped.
    func testRetrySendWhileReconnectBackoffTimesOutGracefully() async throws {
        let service = await makeStartedService()

        // Subscribe BEFORE enqueuing — the stream does not replay, so a deferred
        // subscriber races the synchronous `.messagePending` emit.
        let stream = service.eventStream.subscribe()

        // Reconnect backoff that never reaches `.open`. Count invocations to prove
        // every retry rode the hook.
        let hookCalls = CounterBox()
        await service.setWaitForTransportOpen { _ in
            await hookCalls.increment()
            try? await Task.sleep(nanoseconds: 30_000_000) // short backoff window
            return false // transport never came back to .open
        }

        // Transport still down: the send does nothing, so no USER_MESSAGE echo
        // confirms the draft. Record attempts to assert the retry budget was spent.
        let sendAttempts = CounterBox()
        await service.setRetrySender { _ in
            await sendAttempts.increment()
        }

        let result = await service.prepareUserMessage(text: "msg during reconnect")
        let draftId = try XCTUnwrap(result?.draftId, "enqueue should succeed on a started chat")

        // Collect events into an actor so the background Task and the test body
        // share state without a data race.
        let log = DraftEventLog(draftId: draftId)
        let collector = Task {
            for await event in stream {
                switch event {
                case .messagePending(let id, _):
                    await log.recordPending(id)
                case .messageConfirmed(let id, _):
                    await log.recordConfirmed(id)
                case .messageFailed(let id):
                    await log.recordFailed(id)
                    if id == draftId { return }
                default:
                    break
                }
            }
        }

        // Poll for terminal `.messageFailed` (production: 3s/retry x 3 -> fails on the
        // 4th tick ~12s) with headroom; if it never arrives the message is hung.
        let reachedTerminal = await waitUntil(timeout: 20) {
            await log.sawFailedForDraft()
        }
        collector.cancel()
        service.eventStream.finish()

        let failedCount = await log.failedCountForDraft()
        let sawPendingForDraft = await log.sawPendingForDraft()
        let sawConfirmedForDraft = await log.sawConfirmedForDraft()

        XCTAssertTrue(
            reachedTerminal,
            "a send stuck across a never-recovering reconnect must end as .messageFailed, not hang"
        )
        XCTAssertEqual(
            failedCount, 1,
            "draft must fail exactly once"
        )
        XCTAssertTrue(sawPendingForDraft, "an optimistic .messagePending must precede the failure")
        XCTAssertFalse(sawConfirmedForDraft, "a send that never delivered must not be reported confirmed")

        // Every retry consulted the wait hook and the full budget
        // (`ChatService.maxRetries == 3`) was spent, so both counters land on 3.
        let hooks = await hookCalls.value
        let attempts = await sendAttempts.value
        XCTAssertEqual(
            hooks, 3,
            "every retry in the budget (3) must wait on the transport-open hook before sending"
        )
        XCTAssertEqual(
            attempts, 3,
            "every retry in the budget (3) must reach the send path even while the socket is down"
        )
        XCTAssertEqual(
            hooks, attempts,
            "every retry that consulted the wait hook must also reach the sender (no send swallowed before failure)"
        )

        await service.destroy()
    }
}

// MARK: - Test fixtures

/// Actor-wrapped counter usable from `@Sendable` hook closures.
private actor CounterBox {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// Actor-isolated event-collector state shared by the background Task and the
/// test body, avoiding a data race.
private actor DraftEventLog {
    private let draftId: String
    private var sawPending = false
    private var sawConfirmed = false
    private var failedIds: [String] = []

    init(draftId: String) {
        self.draftId = draftId
    }

    func recordPending(_ id: String) {
        if id == draftId { sawPending = true }
    }

    func recordConfirmed(_ id: String) {
        if id == draftId { sawConfirmed = true }
    }

    func recordFailed(_ id: String) {
        failedIds.append(id)
    }

    func sawPendingForDraft() -> Bool { sawPending }
    func sawConfirmedForDraft() -> Bool { sawConfirmed }
    func sawFailedForDraft() -> Bool { failedIds.contains(draftId) }
    func failedCountForDraft() -> Int { failedIds.filter { $0 == draftId }.count }
}