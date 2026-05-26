import Foundation

actor ChatService {

    private(set) var chatStarted: Bool = false
    private(set) var chatEnded: Bool = false
    private(set) var agentChatEnded: Bool = false
    private(set) var isAgentTyping: Bool = false
    // Backend default is 1 MiB; SESSION_START.capabilities overrides this once
    // the session is established. The initial value only matters in the narrow
    // window between session creation and SESSION_START arrival.
    private(set) var maxMessageSize: Int = 1_048_576
    private(set) var liveAgentName: String?
    private var agentJoinRequested: Bool = false

    private var streamingBuffer: StreamingBuffer?
    private var pendingMessages: [PendingMessage] = []
    private var typingTimer: Task<Void, Never>?
    private var seenEventIds: Set<String> = []

    nonisolated let eventStream = Multicaster<MessagingEvent>()
    private let logger: PolyLogger
    private let greetingMessage: String?
    private var retrySender: (@Sendable (OutgoingEvent) async -> Void)?

    private static let retryIntervalSeconds: TimeInterval = 3
    private static let maxRetries: Int = 3
    private static let typingTimeoutSeconds: TimeInterval = 10

    init(logger: PolyLogger, greetingMessage: String? = nil) {
        self.logger = logger
        self.greetingMessage = greetingMessage
    }

    func setRetrySender(_ sender: @escaping @Sendable (OutgoingEvent) async -> Void) {
        retrySender = sender
    }

    // MARK: - Event routing

    func handleBatch(_ events: [MessagingEvent]) -> [OutgoingEvent] {
        // Pre-scan: if the batch contains AGENT_JOINED, the agent already
        // joined in a prior session. Set the flag BEFORE processing
        // SESSION_START so handleSessionStart doesn't re-send the join.
        for event in events {
            if case .agentJoined = event {
                agentJoinRequested = true
                break
            }
        }
        var allSideEffects: [OutgoingEvent] = []
        for event in events {
            allSideEffects.append(contentsOf: handleMessage(event))
        }
        return allSideEffects
    }

    func handleMessage(_ event: MessagingEvent) -> [OutgoingEvent] {
        // Global dedup by envelope id. Transient events (nil sequence —
        // typing indicators, heartbeats) are excluded so they always pass.
        if let env = event.envelope, env.sequence != nil, !env.id.isEmpty {
            guard seenEventIds.insert(env.id).inserted else { return [] }
        }

        var sideEffects: [OutgoingEvent] = []

        // An incoming server message proves the chat is live, so latched
        // chatEnded clears. Terminal events keep their flag — they're the
        // ones that legitimately set it.
        switch event {
        case .heartbeat, .sessionEnd, .systemMessage, .liveAgentLeft:
            break
        default:
            if chatEnded {
                chatEnded = false
            }
        }

        switch event {
        case .sessionStart(_, let payload):
            sideEffects = handleSessionStart(payload)

        case .sessionEnd:
            handleSessionEnd(event)

        case .agentThinking:
            startTypingIndicator()
            // Forward to consumers — ChatSession (and any direct subscribers)
            // gate their published `isAgentTyping` on this event reaching the
            // public events stream. Without the emit, ChatService kept the
            // flag privately and the UI never showed the indicator.
            eventStream.emit(event)

        case .liveAgentTyping(_, let payload):
            // Honor STOPPED — without this the indicator restarted on every
            // STOPPED frame from the backend (Nice / Salesforce / etc adapters
            // all emit explicit STOPPED states).
            switch payload.state {
            case .started: startTypingIndicator()
            case .stopped: stopTypingIndicator()
            }
            eventStream.emit(event)

        case .agentMessage(let env, let payload):
            handleAgentMessage(env, payload)

        case .agentMessageChunk(let env, let payload):
            handleAgentMessageChunk(env, payload)

        case .liveAgentJoined(_, let payload):
            liveAgentName = payload.agentName
            eventStream.emit(event)

        case .liveAgentMessage:
            stopTypingIndicator()
            eventStream.emit(event)

        case .liveAgentLeft(_, let payload):
            liveAgentName = nil
            // A live agent leaving is NOT a chat-ended signal — they may be
            // handing back to the bot or to another live agent. Only explicit
            // SESSION_END / agentMessage.endConversation / user-initiated end
            // should flip chatEnded.
            eventStream.emit(event)
            if payload.reason != nil {
                logger.info("Live agent left", metadata: nil)
            }

        case .systemMessage(_, let payload):
            // Web preserves chatEnded across systemMessage. No flip in either
            // direction. iOS matches by simply forwarding the event.
            eventStream.emit(event)

            // Auto-recovery: for specific error-level system messages the API
            // defines a recovery action. Re-sending REQUEST_POLY_AGENT_JOIN
            // restarts the conversation on the server side.
            if payload.level == .error {
                let msg = payload.message.lowercased()
                if msg.contains("conversation not found")
                    || msg.contains("conversation id not found")
                    || msg.contains("unable to start a conversation") {
                    logger.info("Auto-recovering from system error", metadata: [
                        "message": payload.message,
                    ])
                    sideEffects.append(.requestPolyAgentJoin())
                }
            }

        case .userMessage(let env, let payload):
            handleUserMessageEcho(env, payload)

        case .handoffQueueStatus, .handoffAccepted, .handoffFailed,
             .handoffTimeout, .clientHandoffRequired, .agentTriggeredHandoff:
            eventStream.emit(event)

        case .agentJoined:
            agentJoinRequested = true
            eventStream.emit(event)

        case .agentLeft:
            eventStream.emit(event)

        case .heartbeat, .userTyping, .userEndSession, .requestPolyAgentJoin:
            break

        case .sessionIdleWarning:
            // Spec-defined but backend not yet sending. Log so it surfaces
            // when it starts arriving without falling silently to default.
            logger.debug("sessionIdleWarning received (no handler yet)", metadata: nil)

        default:
            break
        }

        return sideEffects
    }

    // MARK: - Session lifecycle

    private func handleSessionStart(_ payload: SessionStartPayload) -> [OutgoingEvent] {
        logger.info("handleSessionStart", metadata: ["agentJoinRequested": String(agentJoinRequested)])
        chatStarted = true
        maxMessageSize = payload.capabilities.maxMessageSize

        eventStream.emit(.sessionStart(
            Envelope(id: "", sequence: nil, timestamp: Date()),
            payload
        ))

        if !agentJoinRequested {
            agentJoinRequested = true
            return [.requestPolyAgentJoin(greetingMessage: greetingMessage)]
        }
        return []
    }

    private func handleSessionEnd(_ event: MessagingEvent) {
        // Forward to consumer FIRST so the chat-ended UI (banner + Start New
        // Chat button) renders even if a downstream guard later skips state
        // mutation. ChatSession reads .sessionEnd to flip its `hasEnded` flag.
        eventStream.emit(event)

        guard !chatEnded else { return }
        cleanupStreamingBuffer()
        agentChatEnded = true
        chatEnded = true
        stopTypingIndicator()
    }

    // MARK: - Agent messages

    private func handleAgentMessage(_ env: Envelope, _ payload: AgentMessagePayload) {
        stopTypingIndicator()

        // Web `hasContent` includes chatCallActions (transfer buttons can be
        // the entire content of an agent message). iOS previously dropped
        // these silently.
        let hasContent = !payload.text.isEmpty
            || !payload.attachments.isEmpty
            || !payload.responseSuggestions.isEmpty
            || !payload.chatCallActions.isEmpty

        if hasContent {
            // A fresh agent message ends any "chat ended" latch — the agent
            // is actively responding. Mirrors web `chatService.ts:854` reset.
            if chatEnded && !agentChatEnded {
                chatEnded = false
            }
            eventStream.emit(.agentMessage(env, payload))
        }

        if payload.endConversation {
            // Synthesize a .sessionEnd event so the consumer flips into the
            // ended-chat UI. Server typically follows up with a real
            // EVENT_TYPE_SESSION_END which is idempotent.
            handleSessionEnd(.sessionEnd(env, SessionEndPayload(reason: "agent_ended")))
        }
    }

    // MARK: - Streaming

    private func handleAgentMessageChunk(_ env: Envelope, _ payload: AgentMessageChunkPayload) {
        // If a chunk for a different message id arrives while we still have
        // a buffer open for the previous one, the prior stream was abandoned
        // server-side (handoff, agent failure, etc.) and never sent its
        // `isComplete` chunk. Finalize the old buffer first so its
        // accumulated text emits as a real `.agentMessage` bubble rather
        // than mixing into the new message's text.
        if let existing = streamingBuffer, existing.messageId != payload.messageId {
            cleanupStreamingBuffer()
        }

        if streamingBuffer == nil {
            streamingBuffer = StreamingBuffer(messageId: payload.messageId)
            stopTypingIndicator()
        }

        streamingBuffer?.append(envelope: env, chunk: payload)

        // Emit chunks so consumers can keep their typing indicator alive
        // across long streams. ChatSession only uses chunks to re-extend its
        // 10s typing-dismiss timer — it does NOT append a bubble per chunk
        // (that happens once at completion via `.agentMessage` below).
        // Any consumer rendering bubbles should ignore `.agentMessageChunk`
        // events and only react to the assembled `.agentMessage`.
        eventStream.emit(.agentMessageChunk(env, payload))

        if payload.isComplete {
            stopTypingIndicator()

            guard let buffer = streamingBuffer else {
                streamingBuffer = nil
                return
            }

            if buffer.hasContent {
                let assembled = buffer.finalize()
                eventStream.emit(.agentMessage(env, assembled))
            }
            // Empty final chunk (server signals end with text:"", no attachments/suggestions):
            // discard the placeholder — don't emit an empty agentMessage.

            streamingBuffer = nil
        }
    }

    func cleanupStreamingBuffer() {
        guard let buffer = streamingBuffer else { return }
        if buffer.hasContent {
            let assembled = buffer.finalize()
            // Preserve the last-seen chunk envelope so the server timestamp
            // survives — a synthetic envelope would use Date() which is less
            // accurate for display ordering.
            let env = buffer.lastEnvelope ?? Envelope(
                id: buffer.messageId, sequence: nil, timestamp: Date()
            )
            eventStream.emit(.agentMessage(env, assembled))
        }
        // Empty buffer (no text accumulated): discard placeholder silently
        streamingBuffer = nil
    }

    /// Called by Coordinator on WS close code 1000 without prior SESSION_END.
    /// Idempotent: if SESSION_END already set chatEnded, this is a no-op.
    func onCleanClose() {
        guard !chatEnded else { return }
        cleanupStreamingBuffer()
        chatEnded = true
    }

    // MARK: - Typing indicator

    private func startTypingIndicator() {
        isAgentTyping = true
        typingTimer?.cancel()
        typingTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.typingTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.isAgentTyping = false
        }
    }

    private func stopTypingIndicator() {
        isAgentTyping = false
        typingTimer?.cancel()
        typingTimer = nil
    }

    // MARK: - Pending message model

    private struct PendingMessage {
        let draftId: String
        let clientEventId: String
        let outgoing: OutgoingEvent
        var retries: Int = 0
        var retryTask: Task<Void, Never>?
    }

    // MARK: - Optimistic send

    func prepareUserMessage(text: String) -> (draftId: String, outgoing: OutgoingEvent)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if chatEnded {
            logger.warn("Send dropped — chat has ended", metadata: nil)
            return nil
        }

        if maxMessageSize > 0, trimmed.utf8.count > maxMessageSize {
            let failId = UUID().uuidString
            eventStream.emit(.messageFailed(draftId: failId))
            logger.warn("Message too large", metadata: [
                "bytes": String(trimmed.utf8.count),
                "max": String(maxMessageSize),
            ])
            return nil
        }

        let draftId = UUID().uuidString
        let clientEventId = UUID().uuidString
        let metadata = ["local_id": clientEventId]
        let outgoing = OutgoingEvent.userMessage(text: trimmed, metadata: metadata)

        var pending = PendingMessage(draftId: draftId, clientEventId: clientEventId, outgoing: outgoing)
        pending.retryTask = scheduleRetry(for: draftId)
        pendingMessages.append(pending)

        eventStream.emit(.messagePending(draftId: draftId, text: trimmed))

        return (draftId, outgoing)
    }

    // MARK: - Retry

    private func scheduleRetry(for draftId: String) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.retryIntervalSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.retryIfPending(draftId: draftId)
        }
    }

    private func retryIfPending(draftId: String) {
        guard let idx = pendingMessages.firstIndex(where: { $0.draftId == draftId }) else { return }

        if pendingMessages[idx].retries >= Self.maxRetries {
            let failed = pendingMessages.remove(at: idx)
            failed.retryTask?.cancel()
            logger.warn("Message failed after \(Self.maxRetries) retries", metadata: [
                "draftId": draftId,
                "clientEventId": failed.clientEventId,
            ])
            eventStream.emit(.messageFailed(draftId: draftId))
            return
        }

        pendingMessages[idx].retries += 1
        let outgoing = pendingMessages[idx].outgoing
        let retryCount = pendingMessages[idx].retries
        pendingMessages[idx].retryTask = scheduleRetry(for: draftId)

        logger.info("Retrying message (\(retryCount)/\(Self.maxRetries))", metadata: [
            "draftId": draftId,
        ])

        Task { [retrySender] in
            await retrySender?(outgoing)
        }
    }

    // MARK: - Echo dedup

    private func handleUserMessageEcho(_ env: Envelope, _ payload: UserMessageEchoPayload) {
        let echoClientEventId = env.metadata?.custom?["local_id"]
        let idx: Int? = if let echoClientEventId {
            pendingMessages.firstIndex(where: { $0.clientEventId == echoClientEventId })
        } else {
            pendingMessages.firstIndex(where: {
                if case .userMessage(let text, _) = $0.outgoing { return text == payload.text }
                return false
            })
        }

        if let idx {
            let pending = pendingMessages.remove(at: idx)
            pending.retryTask?.cancel()
            eventStream.emit(.messageConfirmed(draftId: pending.draftId, messageId: payload.messageId))
        } else {
            eventStream.emit(.userMessage(env, payload))
        }
    }

    // MARK: - Reset

    func resetChat(isResume: Bool = false) {
        logger.info("resetChat", metadata: [
            "isResume": String(isResume),
            "prevAgentJoinRequested": String(agentJoinRequested),
        ])
        stopTypingIndicator()
        streamingBuffer = nil
        cancelAllRetries()
        pendingMessages.removeAll()
        chatEnded = false
        agentChatEnded = false
        isAgentTyping = false
        if !isResume {
            seenEventIds.removeAll()
        }
        // Don't assume agent joined on resume — the EVENT_BATCH replay
        // sets agentJoinRequested via .agentJoined if the agent was present.
        agentJoinRequested = false
    }

    func setChatEnded(_ ended: Bool) {
        chatEnded = ended
    }

    private func cancelAllRetries() {
        for msg in pendingMessages {
            msg.retryTask?.cancel()
        }
    }

    func markPendingFailed(draftId: String) {
        if let idx = pendingMessages.firstIndex(where: { $0.draftId == draftId }) {
            pendingMessages[idx].retryTask?.cancel()
            pendingMessages.remove(at: idx)
        }
        eventStream.emit(.messageFailed(draftId: draftId))
    }

    func destroy() {
        stopTypingIndicator()
        cancelAllRetries()
        eventStream.finish()
    }
}

// MARK: - StreamingBuffer

private struct StreamingBuffer {
    let messageId: String
    var lastEnvelope: Envelope?
    private var chunks: [ChunkEntry] = []
    private var seenAttachmentUrls: Set<String> = []

    init(messageId: String) {
        self.messageId = messageId
    }

    private struct ChunkEntry {
        let chunkIndex: Int
        let text: String?
        let attachments: [Attachment]
        let responseSuggestions: [ResponseSuggestion]
    }

    var hasContent: Bool {
        chunks.contains { ($0.text != nil && !$0.text!.isEmpty) || !$0.attachments.isEmpty || !$0.responseSuggestions.isEmpty }
    }

    mutating func append(envelope: Envelope, chunk: AgentMessageChunkPayload) {
        lastEnvelope = envelope
        var dedupedAttachments: [Attachment] = []
        for attachment in chunk.attachments {
            let key = attachment.contentUrl?.absoluteString ?? UUID().uuidString
            if !seenAttachmentUrls.contains(key) {
                seenAttachmentUrls.insert(key)
                dedupedAttachments.append(attachment)
            }
        }
        chunks.append(ChunkEntry(
            chunkIndex: chunk.chunkIndex,
            text: chunk.text,
            attachments: dedupedAttachments,
            responseSuggestions: chunk.responseSuggestions
        ))
    }

    func finalize() -> AgentMessagePayload {
        let sorted = chunks.sorted { $0.chunkIndex < $1.chunkIndex }
        let text = sorted.compactMap { $0.text }.filter { !$0.isEmpty }.joined(separator: " ")
        let attachments = sorted.flatMap { $0.attachments }
        let suggestions = sorted.last(where: { !$0.responseSuggestions.isEmpty })?.responseSuggestions ?? []

        return AgentMessagePayload(
            messageId: messageId,
            text: text,
            agentName: nil,
            avatarUrl: nil,
            attachments: attachments,
            responseSuggestions: suggestions,
            chatCallActions: [],
            endConversation: false
        )
    }
}
