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
}
