// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Deterministic coverage for `ChatSession` — the public state machine every
/// example and customer binds to. Drives the real `Coordinator`/`ChatService`
/// pipeline over a `MockConnection` (no network) and asserts the published
/// state, so these cover the same paths the live XCUITests can only sample:
/// delivery, suggestions, attachments, call actions, typing, end/endConversation,
/// live-agent + handoff system messages, replay/dedup, and the imperative API.
@MainActor
final class ChatSessionTests: XCTestCase {

    /// Retains the client + session for the duration of a test (ChatSession
    /// holds the client; the coordinator/connection hang off it).
    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive.removeAll()
        super.tearDown()
    }

    // MARK: - Stack builder

    private func makeSession(
        streamingEnabled: Bool? = nil,
        open: Bool = true
    ) async throws -> (ChatSession, MockConnection, MockRestApi) {
        // SessionStore persists in UserDefaults; clear so a prior run's stored
        // session doesn't short-circuit resume() and skip createSession.
        SessionStore(apiKey: "test_token").clear()

        let api = MockRestApi()
        let connection = MockConnection()
        let config = Configuration(apiKey: "test_token", environment: .us)
        let logger = NoopLogger()

        let session = SessionService(api: api, config: config, logger: logger)
        let wsURL = URL(string: "wss://messaging.poly.ai/ws")!
        let connService = ConnectionService(transport: connection, wsBaseURL: wsURL, logger: logger)
        let chat = ChatService(logger: logger)
        let heartbeat = HeartbeatService(intervalSeconds: 30)
        let coordinator = Coordinator(
            sessionService: session,
            connectionService: connService,
            chatService: chat,
            heartbeatService: heartbeat,
            logger: logger
        )
        let transport = WebSocketTransport(logger: logger)   // dummy for getConnection(); unused here
        let client = PolyMessagingClient(
            coordinator: coordinator,
            sessionService: session,
            transport: transport,
            config: config,
            autoStart: true
        )
        let chatSession = ChatSession(client: client, streamingEnabled: streamingEnabled)
        keepAlive.append(client)
        keepAlive.append(chatSession)

        try await client.resume()                            // await coordinator.start()
        try? await Task.sleep(nanoseconds: 150_000_000)      // let WS subscribers attach

        if open {
            connection.simulateOpen()
            await assertEventually("connection never opened") {
                if case .open = chatSession.connection { return true }; return false
            }
        }
        return (chatSession, connection, api)
    }

    /// Polls a main-actor condition until true or the deadline passes.
    private func waitUntil(timeout: TimeInterval = 10.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Polls then asserts — the async-friendly form of `XCTAssertTrue`.
    private func assertEventually(
        _ message: String = "condition not met in time",
        timeout: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let ok = await waitUntil(timeout: timeout, condition)
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    // MARK: - Connection / session lifecycle

    func test_open_setsConnectionOpen() async throws {
        let (s, _, _) = try await makeSession()
        XCTAssertEqual(s.connection, .open)
        XCTAssertNil(s.failureReason)
    }

    func test_sessionStart_setsHasStarted() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        await assertEventually { s.hasStarted }
        XCTAssertFalse(s.hasEnded)
    }

    func test_sessionEnd_serverReason_endsAndShowsPill() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.sessionEnd(makeEnvelope(), SessionEndPayload(reason: "agent_ended")))
        await assertEventually { s.hasEnded }
        XCTAssertTrue(s.systemMessages.contains {
            if case .conversationEnded = $0.event { return true }; return false
        })
    }

    func test_sessionEnd_userEnded_endsWithoutPill() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.sessionEnd(makeEnvelope(), SessionEndPayload(reason: "user_ended")))
        await assertEventually { s.hasEnded }
        XCTAssertFalse(s.systemMessages.contains {
            if case .conversationEnded = $0.event { return true }; return false
        })
    }

    // MARK: - Agent messages

    func test_agentMessage_appendsAgentBubble() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e1"),
            makeAgentMessagePayload(messageId: "m1", text: "Hi there")))
        await assertEventually { s.agentMessages.count == 1 }
        XCTAssertEqual(s.agentMessages.first?.text, "Hi there")
        XCTAssertEqual(s.agentMessages.first?.agentKind, .poly)
    }

    func test_agentMessage_withAttachments_surfaced() async throws {
        let (s, conn, _) = try await makeSession()
        let img = Attachment(contentType: .image,
                             contentUrl: URL(string: "https://x/i.png"),
                             title: nil, previewImageUrl: nil, callToActionText: nil)
        let payload = AgentMessagePayload(
            messageId: "m1", text: "see this", agentName: nil, avatarUrl: nil,
            attachments: [img], responseSuggestions: [], chatCallActions: [], endConversation: false)
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e1"), payload))
        await assertEventually { s.lastAgentMessage?.attachments.count == 1 }
        XCTAssertEqual(s.lastAgentMessage?.attachments.first?.contentType, .image)
    }

    func test_agentMessage_withSuggestions_onLastAgentMessage() async throws {
        let (s, conn, _) = try await makeSession()
        let payload = AgentMessagePayload(
            messageId: "m1", text: "pick one", agentName: nil, avatarUrl: nil,
            attachments: [],
            responseSuggestions: [ResponseSuggestion(messageText: "Yes"),
                                  ResponseSuggestion(messageText: "No")],
            chatCallActions: [], endConversation: false)
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e1"), payload))
        await assertEventually { s.lastAgentMessage?.suggestions.count == 2 }
        XCTAssertEqual(s.lastAgentMessage?.suggestions.map { $0.messageText }, ["Yes", "No"])
    }

    func test_agentMessage_withCallActions_surfaced() async throws {
        let (s, conn, _) = try await makeSession()
        let payload = AgentMessagePayload(
            messageId: "m1", text: "call us", agentName: nil, avatarUrl: nil,
            attachments: [], responseSuggestions: [],
            chatCallActions: [ChatCallAction(title: "Call", contactNumber: "+1 555 0100")],
            endConversation: false)
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e1"), payload))
        await assertEventually { s.lastAgentMessage?.callActions.count == 1 }
        XCTAssertEqual(s.lastAgentMessage?.callActions.first?.contactNumber, "+1 555 0100")
    }

    func test_agentMessage_setsAgentAvatarUrl() async throws {
        let (s, conn, _) = try await makeSession()
        let avatar = URL(string: "https://x/avatar.png")!
        let payload = AgentMessagePayload(
            messageId: "m1", text: "hi", agentName: "Webby", avatarUrl: avatar,
            attachments: [], responseSuggestions: [], chatCallActions: [], endConversation: false)
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e1"), payload))
        await assertEventually { s.agentAvatarUrl == avatar }
    }

    // MARK: - Typing indicator

    func test_agentThinking_setsTyping_thenAgentMessageClears() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.agentThinking(makeEnvelope()))
        await assertEventually { s.isAgentTyping }
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e2"),
            makeAgentMessagePayload(messageId: "m1", text: "done")))
        await assertEventually { !s.isAgentTyping }
    }

    func test_liveAgentTyping_startedThenStopped() async throws {
        let (s, conn, _) = try await makeSession()
        // Real typing frames carry a nil sequence (transient, dedup-exempt);
        // distinct envelopes keep ChatService's id-dedup from dropping STOPPED.
        conn.simulateMessage(.liveAgentTyping(makeEnvelope(id: "ty1", sequence: nil),
            LiveAgentTypingPayload(state: .started, agentId: nil, agentName: "Sam")))
        await assertEventually { s.isAgentTyping }
        conn.simulateMessage(.liveAgentTyping(makeEnvelope(id: "ty2", sequence: nil),
            LiveAgentTypingPayload(state: .stopped, agentId: nil, agentName: "Sam")))
        await assertEventually { !s.isAgentTyping }
    }

    // MARK: - Send + delivery state

    func test_send_appendsPendingUserBubble() async throws {
        let (s, _, _) = try await makeSession()
        try await s.send("Hello")
        await assertEventually { s.userMessages.count == 1 }
        XCTAssertEqual(s.userMessages.first?.text, "Hello")
        XCTAssertEqual(s.userMessages.first?.delivery, .pending)
    }

    func test_sendThenEcho_confirmsDelivery() async throws {
        let (s, conn, _) = try await makeSession()
        try await s.send("Hello")
        await assertEventually { s.userMessages.first?.delivery == .pending }
        // Server echoes the message back -> ChatService correlates -> confirmed.
        conn.simulateMessage(.userMessage(makeEnvelope(id: "echo1"),
            UserMessageEchoPayload(messageId: "server_1", text: "Hello")))
        await assertEventually { s.userMessages.first?.delivery == .sent }
    }

    // MARK: - Live agent + handoff

    func test_liveAgentJoined_appendsSystemPill_andAvatar() async throws {
        let (s, conn, _) = try await makeSession()
        let avatar = URL(string: "https://x/sam.png")!
        conn.simulateMessage(.liveAgentJoined(makeEnvelope(),
            LiveAgentJoinedPayload(agentId: "a1", agentName: "Sam", avatarUrl: avatar)))
        await assertEventually {
            s.systemMessages.contains { if case .liveAgentJoined = $0.event { return true }; return false }
        }
        XCTAssertEqual(s.agentAvatarUrl, avatar)
    }

    func test_liveAgentMessage_appendsLiveBubble() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.liveAgentMessage(makeEnvelope(),
            LiveAgentMessagePayload(messageId: "lm1", text: "human here", agentId: "a1",
                agentName: "Sam", avatarUrl: nil, attachments: [],
                responseSuggestions: [], chatCallActions: [])))
        await assertEventually { s.agentMessages.contains { $0.agentKind == .live } }
        XCTAssertEqual(s.agentMessages.last?.text, "human here")
    }

    func test_liveAgentLeft_endsConversation() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.liveAgentLeft(makeEnvelope(),
            LiveAgentLeftPayload(agentId: "a1", agentName: "Sam", reason: "resolved")))
        await assertEventually { s.hasEnded }
    }

    func test_agentTriggeredHandoff_appendsStartedPill() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.agentTriggeredHandoff(makeEnvelope()))
        await assertEventually {
            s.systemMessages.contains { if case .handoffStarted = $0.event { return true }; return false }
        }
    }

    func test_handoffQueueStatus_appendsQueuePill() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.handoffQueueStatus(makeEnvelope(),
            HandoffQueueStatusPayload(position: 3, estimatedWaitSeconds: 120,
                                      queueName: "support", displayMessage: "You are #3")))
        await assertEventually {
            s.systemMessages.contains {
                if case .queueStatus(let pos, _) = $0.event { return pos == 3 }; return false
            }
        }
    }

    func test_handoffFailed_appendsPillWithReason() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.handoffFailed(makeEnvelope(),
            HandoffFailedPayload(reason: "no_agents")))
        await assertEventually {
            s.systemMessages.contains {
                if case .handoffFailed(let r) = $0.event { return r == "no_agents" }; return false
            }
        }
    }

    func test_handoffTimeout_appendsPill() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.handoffTimeout(makeEnvelope(), HandoffTimeoutPayload(reason: nil)))
        await assertEventually {
            s.systemMessages.contains { if case .handoffTimeout = $0.event { return true }; return false }
        }
    }

    // MARK: - Replay / dedup

    func test_userMessageReplay_appendsSentBubble_andDedups() async throws {
        let (s, conn, _) = try await makeSession()
        let env = makeEnvelope(id: "u1")
        conn.simulateMessage(.userMessage(env, UserMessageEchoPayload(messageId: "s1", text: "earlier")))
        await assertEventually { s.userMessages.count == 1 }
        XCTAssertEqual(s.userMessages.first?.delivery, .sent)
        // Same envelope id replayed -> no duplicate.
        conn.simulateMessage(.userMessage(env, UserMessageEchoPayload(messageId: "s1", text: "earlier")))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(s.userMessages.count, 1)
    }

    // MARK: - Streaming

    func test_chunkedAgentMessage_rendersAsSingleBubble() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload(streaming: true)))
        await assertEventually { s.hasStarted }
        // ChatService.finalize() joins non-empty chunk texts with a space.
        conn.simulateMessage(.agentMessageChunk(makeEnvelope(id: "c0"),
            makeChunkPayload(messageId: "ms1", chunkIndex: 0, isComplete: false, text: "Hello")))
        conn.simulateMessage(.agentMessageChunk(makeEnvelope(id: "c1"),
            makeChunkPayload(messageId: "ms1", chunkIndex: 1, isComplete: true, text: "there")))
        await assertEventually("chunks should assemble into a single bubble") {
            s.agentMessages.count == 1 && s.agentMessages.first?.text == "Hello there"
        }
    }

    // MARK: - Imperative API

    func test_removeMessage_removesPendingDraft() async throws {
        let (s, _, _) = try await makeSession()
        try await s.send("oops")
        await assertEventually { s.userMessages.count == 1 }
        let draftId = s.userMessages.first?.draftId
        XCTAssertNotNil(draftId)
        s.removeMessage(draftId: draftId!)
        XCTAssertEqual(s.userMessages.count, 0)
    }

    func test_clearSuggestions_clearsOnAgentMessage() async throws {
        let (s, conn, _) = try await makeSession()
        let payload = AgentMessagePayload(
            messageId: "m1", text: "pick", agentName: nil, avatarUrl: nil,
            attachments: [], responseSuggestions: [ResponseSuggestion(messageText: "A")],
            chatCallActions: [], endConversation: false)
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e1"), payload))
        await assertEventually { s.lastAgentMessage?.suggestions.count == 1 }
        let id = s.messages.last!.id
        s.clearSuggestions(for: id)
        XCTAssertEqual(s.lastAgentMessage?.suggestions.count, 0)
    }

    func test_clearChat_resetsState() async throws {
        let (s, conn, _) = try await makeSession()
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        conn.simulateMessage(.agentMessage(makeEnvelope(id: "e1"),
            makeAgentMessagePayload(messageId: "m1", text: "hi")))
        await assertEventually { s.agentMessages.count == 1 && s.hasStarted }
        s.clearChat()
        XCTAssertEqual(s.messages.count, 0)
        XCTAssertFalse(s.hasStarted)
        XCTAssertFalse(s.hasEnded)
    }
}
