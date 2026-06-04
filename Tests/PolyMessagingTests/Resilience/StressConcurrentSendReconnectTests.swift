// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Stress / robustness probes for the intersection of optimistic sends and the
/// reconnect ladder. The retry machinery in `ChatService` is wired up with two
/// Coordinator-supplied hooks:
///
///   * `waitForTransportOpen` — a retry pauses on this until the transport
///     flips back to `.open` (returns `true`) or the wait times out
///     (returns `false`).
///   * `retrySender` — performs the actual send once the wait resolves.
///
/// These tests drive those hooks directly (no Coordinator) so the failure-mode
/// timing is deterministic. They assert the invariant that a send caught in a
/// reconnect window always reaches a terminal outcome — confirmed or failed —
/// and is never left hung or silently dropped.
final class StressConcurrentSendReconnectTests: XCTestCase {

    private func makeStartedService() async -> ChatService {
        let service = ChatService(logger: NoopLogger())
        // SESSION_START flips `chatStarted = true` so prepareUserMessage will
        // enqueue rather than no-op.
        _ = await service.handleMessage(
            MessagingEvent.sessionStart(
                makeEnvelope(id: "evt_boot"), makeSessionStartPayload()
            )
        )
        return service
    }

    // MARK: -

    /// A send is enqueued, then every retry attempt lands while the SDK is
    /// mid-reconnect: the `waitForTransportOpen` hook keeps timing out (returns
    /// `false`) and the `retrySender` cannot actually deliver (the new socket
    /// never comes up, so no USER_MESSAGE echo ever confirms the draft).
    ///
    /// The invariant under test: the message is NOT left pending forever and is
    /// NOT silently dropped — after the retry budget is exhausted the consumer
    /// receives exactly one `.messageFailed` for that draft. Each retry must
    /// also have consulted the wait hook (so reconnect-aware backoff is honored
    /// rather than the retry blindly firing into a dead socket), and the full
    /// retry budget (`maxRetries == 3`) must be spent before giving up.
    func testRetrySendWhileReconnectBackoffTimesOutGracefully() async throws {
        let service = await makeStartedService()

        // Subscribe BEFORE enqueuing — the event stream does not replay, and a
        // deferred subscriber races the synchronous `.messagePending` emit.
        let stream = service.eventStream.subscribe()

        // Simulate reconnect backoff that never reaches `.open`: the hook waits
        // briefly (a short, bounded timeout — mimicking the cap a caller would
        // pass) and then reports failure. Count invocations to prove every
        // retry rode the hook.
        let hookCalls = CounterBox()
        await service.setWaitForTransportOpen { _ in
            await hookCalls.increment()
            try? await Task.sleep(nanoseconds: 30_000_000) // short backoff window
            return false // transport never came back to .open
        }

        // The transport is still down, so the send "fails" by doing nothing:
        // no frame leaves, and crucially no USER_MESSAGE echo ever arrives to
        // confirm the draft. Record attempts so we can assert the retry budget
        // was actually spent before failure.
        let sendAttempts = CounterBox()
        await service.setRetrySender { _ in
            await sendAttempts.increment()
        }

        let result = await service.prepareUserMessage(text: "msg during reconnect")
        let draftId = try XCTUnwrap(result?.draftId, "enqueue should succeed on a started chat")

        // Collect events into an actor — the collector runs on a background
        // Task and the test body reads the same state, so all access must be
        // synchronized to avoid a data race.
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

        // Wait for the terminal `.messageFailed` rather than sleeping a fixed
        // span. Production timing: retry fires every 3s, budget is 3 retries,
        // so the failure latch trips on the 4th retry tick (~12s). Poll on the
        // real condition with generous headroom; if it never arrives the
        // message is hung -> the wait returns false and the assertion below
        // fails.
        let reachedTerminal = await waitUntil(timeout: 20) {
            await log.sawFailedForDraft()
        }
        collector.cancel()
        service.eventStream.finish()

        let failedCount = await log.failedCountForDraft()
        let sawPendingForDraft = await log.sawPendingForDraft()
        let sawConfirmedForDraft = await log.sawConfirmedForDraft()

        // Terminal outcome reached: the draft is FAILED, not hung.
        XCTAssertTrue(
            reachedTerminal,
            "a send stuck across a never-recovering reconnect must end as .messageFailed, not hang"
        )
        // Exactly one terminal failure for the draft — not a storm of them.
        XCTAssertEqual(
            failedCount, 1,
            "draft must fail exactly once"
        )
        // It was genuinely pending first (optimistic bubble shown), and never
        // got confirmed (transport never recovered).
        XCTAssertTrue(sawPendingForDraft, "an optimistic .messagePending must precede the failure")
        XCTAssertFalse(sawConfirmedForDraft, "a send that never delivered must not be reported confirmed")

        // Every retry consulted the reconnect-aware wait hook, and the retry
        // budget (`ChatService.maxRetries == 3`) was spent in full before
        // giving up — proving the send wasn't silently dropped on the first
        // stumble. The 4th retry tick observes the budget exhausted and emits
        // `.messageFailed` without scheduling another send, so both counters
        // land on exactly 3.
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

/// Synchronizes the event-collector state that is written from a background
/// `Task` and read from the test body. Tracks per-draft pending / confirmed /
/// failed observations behind actor isolation so there is no data race.
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