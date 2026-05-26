// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class ChatServiceTests: XCTestCase {

    private func makeService() -> ChatService {
        ChatService(logger: NoopLogger())
    }

    // MARK: - Session start

    func testSessionStartSetsChatStartedAndReturnsAgentJoin() async {
        let service = makeService()
        let event = MessagingEvent.sessionStart(
            makeEnvelope(), makeSessionStartPayload(maxMessageSize: 131_072)
        )

        let effects = await service.handleMessage(event)
        XCTAssertEqual(effects.count, 1)
        if case .requestPolyAgentJoin = effects.first {} else {
            XCTFail("Expected requestPolyAgentJoin")
        }

        let started = await service.chatStarted
        XCTAssertTrue(started)

        let maxSize = await service.maxMessageSize
        XCTAssertEqual(maxSize, 131_072)
    }

    func testSessionStartDoesNotResendAgentJoinOnResume() async {
        let service = makeService()
        await service.resetChat(isResume: true)

        // Simulate EVENT_BATCH replay containing agentJoined
        let joinedEvent = MessagingEvent.agentJoined(
            makeEnvelope(), AgentJoinedPayload(agentName: "Ada", avatarUrl: nil)
        )
        _ = await service.handleMessage(joinedEvent)

        let event = MessagingEvent.sessionStart(
            makeEnvelope(), makeSessionStartPayload()
        )
        let effects = await service.handleMessage(event)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Session end

    func testSessionEndSetsChatEnded() async {
        let service = makeService()
        let event = MessagingEvent.sessionEnd(
            makeEnvelope(), SessionEndPayload(reason: "normal")
        )
        _ = await service.handleMessage(event)

        let ended = await service.chatEnded
        XCTAssertTrue(ended)

        let agentEnded = await service.agentChatEnded
        XCTAssertTrue(agentEnded)
    }

    func testSessionEndIsIdempotent() async {
        let service = makeService()
        let event = MessagingEvent.sessionEnd(
            makeEnvelope(), SessionEndPayload(reason: nil)
        )
        _ = await service.handleMessage(event)
        _ = await service.handleMessage(event)

        let ended = await service.chatEnded
        XCTAssertTrue(ended)
    }

    // MARK: - Agent message with endConversation

    func testAgentMessageWithEndConversationEndsChatAsync() async {
        let service = makeService()
        let event = MessagingEvent.agentMessage(
            makeEnvelope(),
            makeAgentMessagePayload(text: "Goodbye!", endConversation: true)
        )
        _ = await service.handleMessage(event)

        let ended = await service.chatEnded
        XCTAssertTrue(ended)
    }

    func testAgentMessageWithoutEndConversationDoesNotEnd() async {
        let service = makeService()
        let event = MessagingEvent.agentMessage(
            makeEnvelope(),
            makeAgentMessagePayload(text: "Hello", endConversation: false)
        )
        _ = await service.handleMessage(event)

        let ended = await service.chatEnded
        XCTAssertFalse(ended)
    }

    // MARK: - Empty agent message discarded

    func testEmptyAgentMessageNotEmitted() async {
        let service = makeService()
        let event = MessagingEvent.agentMessage(
            makeEnvelope(),
            AgentMessagePayload(
                messageId: "m1", text: "", agentName: nil, avatarUrl: nil,
                attachments: [], responseSuggestions: [],
                chatCallActions: [], endConversation: false
            )
        )

        // Subscribe synchronously then finish()+drain — a deferred Task can
        // attach after the emit (the stream doesn't replay), which races the
        // assertion. Deterministic: capture everything emitted, assert none.
        let stream = service.eventStream.subscribe()
        _ = await service.handleMessage(event)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await e in stream { emitted.append(e) }
        let agentMessages = emitted.filter {
            if case .agentMessage = $0 { return true }
            return false
        }
        XCTAssertTrue(agentMessages.isEmpty, "empty agent message should not be emitted")
    }

    // MARK: - Streaming chunks

    func testStreamingChunksAssembleIntoFinalMessage() async {
        let service = makeService()

        // Subscribe BEFORE triggering events
        let stream = service.eventStream.subscribe()

        let chunk1 = MessagingEvent.agentMessageChunk(
            makeEnvelope(id: "e1"),
            makeChunkPayload(messageId: "m1", chunkIndex: 0, text: "Hello")
        )
        let chunk2 = MessagingEvent.agentMessageChunk(
            makeEnvelope(id: "e2"),
            makeChunkPayload(messageId: "m1", chunkIndex: 1, text: "world")
        )
        let chunk3 = MessagingEvent.agentMessageChunk(
            makeEnvelope(id: "e3"),
            makeChunkPayload(messageId: "m1", chunkIndex: 2, isComplete: true, text: "!")
        )

        _ = await service.handleMessage(chunk1)
        _ = await service.handleMessage(chunk2)
        _ = await service.handleMessage(chunk3)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let agentMessages = emitted.filter {
            if case .agentMessage = $0 { return true }
            return false
        }
        XCTAssertEqual(agentMessages.count, 1)

        if case .agentMessage(_, let payload) = agentMessages.first {
            XCTAssertEqual(payload.text, "Hello world !")
        }
    }

    func testEmptyFinalChunkDiscarded() async {
        let service = makeService()

        let chunk1 = MessagingEvent.agentMessageChunk(
            makeEnvelope(id: "e1"),
            makeChunkPayload(messageId: "m1", chunkIndex: 0, text: "partial")
        )
        let finalEmpty = MessagingEvent.agentMessageChunk(
            makeEnvelope(id: "e2"),
            AgentMessageChunkPayload(
                messageId: "m1", chunkIndex: 1, isComplete: true,
                text: "", attachments: [], responseSuggestions: []
            )
        )

        let stream = service.eventStream.subscribe()
        _ = await service.handleMessage(chunk1)
        _ = await service.handleMessage(finalEmpty)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        // Should still assemble because chunk1 had text "partial"
        let assembled = emitted.filter {
            if case .agentMessage = $0 { return true }
            return false
        }
        XCTAssertEqual(assembled.count, 1)
        if case .agentMessage(_, let p) = assembled.first {
            XCTAssertEqual(p.text, "partial")
        }
    }

    func testCompletelyEmptyStreamDiscarded() async {
        let service = makeService()

        let emptyChunk = MessagingEvent.agentMessageChunk(
            makeEnvelope(id: "e1"),
            AgentMessageChunkPayload(
                messageId: "m1", chunkIndex: 0, isComplete: true,
                text: "", attachments: [], responseSuggestions: []
            )
        )

        let stream = service.eventStream.subscribe()
        _ = await service.handleMessage(emptyChunk)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let assembled = emitted.filter {
            if case .agentMessage = $0 { return true }
            return false
        }
        XCTAssertTrue(assembled.isEmpty, "Empty stream should not produce an assembled message")
    }

    // MARK: - Optimistic send

    func testPrepareUserMessageEmitsPending() async {
        let service = makeService()

        let result = await service.prepareUserMessage(text: "Hello")
        XCTAssertNotNil(result)
        if case .userMessage(let text, _) = result?.outgoing {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected userMessage outgoing event")
        }
        XCTAssertFalse(result!.draftId.isEmpty)
    }

    func testPrepareUserMessageRejectsEmpty() async {
        let service = makeService()
        let result = await service.prepareUserMessage(text: "   ")
        XCTAssertNil(result)
    }

    func testPrepareUserMessageRejectsOversized() async {
        let service = makeService()
        // Set a small max size
        let startEvent = MessagingEvent.sessionStart(
            makeEnvelope(), makeSessionStartPayload(maxMessageSize: 10)
        )
        _ = await service.handleMessage(startEvent)

        let result = await service.prepareUserMessage(text: "This is way too long for the limit")
        XCTAssertNil(result)
    }

    // MARK: - Dedup

    func testEchoMatchesPendingByText() async {
        let service = makeService()

        // Subscribe before triggering. The event stream does not replay, and
        // subscribing inside a deferred Task races the emits below — on a slow
        // runner prepareUserMessage/handleMessage can fire before the Task
        // attaches, dropping .messageConfirmed (flaky). Drain synchronously.
        let stream = service.eventStream.subscribe()

        let result = await service.prepareUserMessage(text: "Hello")!
        let echo = MessagingEvent.userMessage(
            makeEnvelope(),
            UserMessageEchoPayload(messageId: "server_id_1", text: "Hello")
        )
        _ = await service.handleMessage(echo)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let confirmed = emitted.filter {
            if case .messageConfirmed = $0 { return true }
            return false
        }
        XCTAssertEqual(confirmed.count, 1)
        if case .messageConfirmed(let draftId, let messageId) = confirmed.first {
            XCTAssertEqual(draftId, result.draftId)
            XCTAssertEqual(messageId, "server_id_1")
        }
    }

    func testEchoWithNoMatchPassesThrough() async {
        let service = makeService()

        // Subscribe before triggering
        let stream = service.eventStream.subscribe()

        let echo = MessagingEvent.userMessage(
            makeEnvelope(),
            UserMessageEchoPayload(messageId: "sid_1", text: "From another tab")
        )
        _ = await service.handleMessage(echo)
        service.eventStream.finish()

        var emitted: [MessagingEvent] = []
        for await event in stream { emitted.append(event) }

        let userMessages = emitted.filter {
            if case .userMessage = $0 { return true }
            return false
        }
        XCTAssertEqual(userMessages.count, 1)
    }

    // MARK: - Clean close

    func testOnCleanCloseSetsChatEnded() async {
        let service = makeService()
        await service.onCleanClose()

        let ended = await service.chatEnded
        XCTAssertTrue(ended)
    }

    func testOnCleanCloseIsIdempotent() async {
        let service = makeService()
        let event = MessagingEvent.sessionEnd(
            makeEnvelope(), SessionEndPayload(reason: nil)
        )
        _ = await service.handleMessage(event)

        // Second close should be a no-op
        await service.onCleanClose()
        let ended = await service.chatEnded
        XCTAssertTrue(ended)
    }

    // MARK: - Reset

    func testResetChatClearsState() async {
        let service = makeService()
        _ = await service.handleMessage(
            MessagingEvent.sessionEnd(makeEnvelope(), SessionEndPayload(reason: nil))
        )

        await service.resetChat(isResume: false)

        let ended = await service.chatEnded
        XCTAssertFalse(ended)

        let agentEnded = await service.agentChatEnded
        XCTAssertFalse(agentEnded)
    }

    func testResetChatPreservesMaxMessageSize() async {
        let service = makeService()
        _ = await service.handleMessage(
            MessagingEvent.sessionStart(
                makeEnvelope(), makeSessionStartPayload(maxMessageSize: 12345)
            )
        )

        await service.resetChat(isResume: false)

        let maxSize = await service.maxMessageSize
        XCTAssertEqual(maxSize, 12345)
    }

    // MARK: - Typing indicator

    func testAgentThinkingSetsTypingFlag() async {
        let service = makeService()
        _ = await service.handleMessage(MessagingEvent.agentThinking(makeEnvelope()))

        let typing = await service.isAgentTyping
        XCTAssertTrue(typing)
    }

    func testAgentMessageClearsTypingFlag() async {
        let service = makeService()
        _ = await service.handleMessage(MessagingEvent.agentThinking(makeEnvelope(id: "evt_think")))
        _ = await service.handleMessage(
            MessagingEvent.agentMessage(makeEnvelope(id: "evt_msg"), makeAgentMessagePayload())
        )

        let typing = await service.isAgentTyping
        XCTAssertFalse(typing)
    }

    // MARK: - Destroy

    func testDestroyFinishesStream() async {
        let service = makeService()
        await service.destroy()
        // Should not crash
    }

    // MARK: - Retry waits for transport open (BUG 3 regression)
    //
    // Regression for the post-reconnect send hang: the retry ladder must
    // pause on the injected `waitForTransportOpen` hook before invoking
    // the retrySender. When the hook resolves `true` mid-retry (transport
    // flipped to `.open`), the retry then proceeds and the send is
    // delivered. Pre-fix, a send during the reconnect window would either
    // be silently dropped (transport returned without throwing) or burn
    // the entire 3-retry budget before reconnect completed.

    func testRetryAwaitsTransportOpenBeforeSending() async throws {
        let service = makeService()
        // sessionStart sets `chatStarted = true` so prepareUserMessage
        // is willing to enqueue.
        _ = await service.handleMessage(
            MessagingEvent.sessionStart(
                makeEnvelope(id: "evt_boot"), makeSessionStartPayload()
            )
        )

        // The hook simulates: transport is `.connecting` when the retry
        // fires, then flips to `.open` ~100ms later. The wait returns
        // `true` once we observe the flip.
        let transportOpenedAt = TimestampBox()
        await service.setWaitForTransportOpen { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            await transportOpenedAt.set(Date())
            return true
        }

        // Capture send calls so we can assert ordering: the retrySender
        // must be invoked AFTER the wait hook resolves.
        let sendBox = SendRecorderBox()
        await service.setRetrySender { outgoing in
            await sendBox.record(outgoing, at: Date())
        }

        // Kick off a send. retryIntervalSeconds = 3 in production, so we
        // wait long enough for the first retry to fire (3s + 100ms hook +
        // a small margin).
        _ = await service.prepareUserMessage(text: "hello after reconnect")

        // Wait for the first retry to fire and complete.
        let deadline = Date().addingTimeInterval(5)
        while await sendBox.count == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let count = await sendBox.count
        XCTAssertGreaterThanOrEqual(count, 1, "Retry should fire and complete the send")

        let firstSendAt = await sendBox.firstAt
        let openAt = await transportOpenedAt.value
        if let firstSendAt, let openAt {
            XCTAssertGreaterThanOrEqual(
                firstSendAt, openAt,
                "Retry send must happen AFTER waitForTransportOpen resolves"
            )
        } else {
            XCTFail("Expected both transportOpened timestamp and firstSend timestamp to be set")
        }

        // Cancel pending retry tasks so subsequent tests in the same run
        // aren't perturbed by background work (the 3s retry timer would
        // keep firing the wait hook + retrySender otherwise).
        await service.destroy()
    }
}

// MARK: - Test fixtures for the retry-wait regression

/// Helper to record send invocations from a @Sendable closure.
private actor SendRecorderBox {
    private(set) var sends: [(OutgoingEvent, Date)] = []
    func record(_ event: OutgoingEvent, at date: Date) { sends.append((event, date)) }
    var count: Int { sends.count }
    var firstAt: Date? { sends.first?.1 }
}

/// Tiny actor-wrapped timestamp slot.
private actor TimestampBox {
    private(set) var value: Date?
    func set(_ d: Date) { value = d }
}
