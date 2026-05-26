// Copyright PolyAI Limited

import Foundation
import Combine

@MainActor
public final class ChatSession: ObservableObject {

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var connection: ConnectionStatus = .idle
    @Published public private(set) var isAgentTyping: Bool = false
    @Published public private(set) var agentAvatarUrl: URL?
    @Published public private(set) var hasStarted: Bool = false
    @Published public private(set) var hasEnded: Bool = false
    /// True once the session can exchange messages.
    @Published public private(set) var isReady: Bool = false
    /// Non-nil when the chat has hit a terminal failure it can't auto-recover
    /// from. Today that covers an invalid connector token rejected during the
    /// initial connect, the reconnect budget being exhausted, and an expired
    /// session. UIs typically render this as a full-screen error state with a
    /// manual retry affordance that calls `client.resume()`.
    @Published public private(set) var failureReason: PolyError?

    public let client: PolyMessagingClient
    private let typingTimeout: TimeInterval
    private let streamingOverride: Bool?
    private var eventTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var connectionStatusTask: Task<Void, Never>?
    private var typingDismissTask: Task<Void, Never>?
    private var streamingBubbles: [String: UUID] = [:]
    private var currentSessionId: String?

    /// Whether agent replies render token-by-token (true) or as completed
    /// bubbles only (false). The per-session override wins; otherwise this
    /// falls through to `Configuration.streamingEnabled` from `initialize(...)`.
    private var streamsProgressively: Bool {
        streamingOverride ?? client.config.streamingEnabled
    }

    /// - Parameters:
    ///   - streamingEnabled: optional per-session override. `nil` (the default)
    ///     uses `Configuration.streamingEnabled` from `initialize(...)`.
    public init(
        client: PolyMessagingClient,
        typingTimeout: TimeInterval = 10,
        streamingEnabled: Bool? = nil
    ) {
        self.client = client
        self.typingTimeout = typingTimeout
        self.streamingOverride = streamingEnabled
        subscribe()
    }

    deinit {
        eventTask?.cancel()
        sessionStateTask?.cancel()
        connectionStatusTask?.cancel()
        typingDismissTask?.cancel()
    }

    public func send(_ text: String) async throws {
        try await client.send(text)
    }

    public func sendTyping() async {
        try? await client.sendTyping()
    }

    public func end() async throws {
        try await client.end()
    }

    public var userMessages: [UserMessage] {
        messages.compactMap { if case .user(let m) = $0 { return m }; return nil }
    }

    public var agentMessages: [AgentMessage] {
        messages.compactMap { if case .agent(let m) = $0 { return m }; return nil }
    }

    public var systemMessages: [SystemMessage] {
        messages.compactMap { if case .system(let m) = $0 { return m }; return nil }
    }

    public var lastAgentMessage: AgentMessage? {
        messages.last { if case .agent = $0 { return true }; return false }
            .flatMap { if case .agent(let m) = $0 { return m }; return nil }
    }

    public func removeMessage(draftId: String) {
        messages.removeAll {
            if case .user(let u) = $0 { return u.draftId == draftId }
            return false
        }
    }

    public func clearSuggestions(for messageId: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        if case .agent(var msg) = messages[idx] {
            msg.suggestions = []
            messages[idx] = .agent(msg)
        }
    }

    // MARK: - Event handling

    private func subscribe() {
        let eventStream = client.events
        eventTask = Task { [weak self] in
            for await event in eventStream {
                guard let self else { return }
                self.handle(event)
            }
        }

        let sessionStream = client.sessionState
        sessionStateTask = Task { [weak self] in
            for await state in sessionStream {
                guard let self else { return }
                self.isReady = state.isReady
                self.applySessionIdChange(state.sessionId)
                // An invalid connector token rejected during the initial
                // connect throws inside Coordinator.start() and never reaches
                // connectionStatus.failed. Surface it here so failureReason
                // remains the single source of truth for terminal failures.
                if state.hasInvalidConnectorToken {
                    self.failureReason = .auth(.unauthorized)
                    self.clearTypingIndicator()
                }
            }
        }

        let statusStream = client.connectionStatus
        connectionStatusTask = Task { [weak self] in
            for await status in statusStream {
                guard let self else { return }
                if case .failed(let reason) = status {
                    self.connection = .failed(reason: reason)
                    self.failureReason = reason
                    self.clearTypingIndicator()
                }
            }
        }
    }

    private func handle(_ event: MessagingEvent) {
        switch event {

        case .connected:
            connection = .open
            failureReason = nil

        case .reconnecting(let attempt):
            connection = .reconnecting(attempt: attempt)

        case .disconnected(let err):
            connection = .closed(nil)
            if err?.isSessionExpired == true {
                hasEnded = true
                clearTypingIndicator()
            }

        case .sessionStart:
            hasStarted = true
            hasEnded = false
            failureReason = nil

        case .sessionEnd(_, let r):
            clearTypingIndicator()
            if r.reason != "user_ended" {
                // Server/agent ended the conversation — render the pill.
                markConversationEnded(reason: r.reason)
            } else {
                // User initiated the end. Skip the pill (their own UI just
                // triggered this) but still reflect the ended state so the
                // app can disable input / surface a "Start New Chat" path.
                hasEnded = true
            }

        case .agentThinking:
            startTypingIndicator()

        case .liveAgentTyping(_, let payload):
            switch payload.state {
            case .started: startTypingIndicator()
            case .stopped: clearTypingIndicator()
            }

        case .agentMessage(_, let m):
            clearTypingIndicator()
            if let url = m.avatarUrl { agentAvatarUrl = url }
            if let bubbleId = streamingBubbles.removeValue(forKey: m.messageId),
               let idx = messages.firstIndex(where: { $0.id == bubbleId }) {
                messages[idx] = .agent(AgentMessage(
                    id: bubbleId,
                    messageId: m.messageId,
                    agentName: m.agentName,
                    agentKind: .poly,
                    avatarUrl: m.avatarUrl,
                    text: m.text,
                    attachments: m.attachments,
                    suggestions: m.responseSuggestions,
                    callActions: m.chatCallActions
                ))
            } else {
                messages.append(.agent(AgentMessage(
                    messageId: m.messageId,
                    agentName: m.agentName,
                    agentKind: .poly,
                    avatarUrl: m.avatarUrl,
                    text: m.text,
                    attachments: m.attachments,
                    suggestions: m.responseSuggestions,
                    callActions: m.chatCallActions
                )))
            }

        case .agentMessageChunk(_, let p) where streamsProgressively:
            clearTypingIndicator()
            let msgId = p.messageId
            if let bubbleId = streamingBubbles[msgId],
               let idx = messages.firstIndex(where: { $0.id == bubbleId }),
               case .agent(let existing) = messages[idx] {
                messages[idx] = .agent(AgentMessage(
                    id: existing.id,
                    messageId: existing.messageId,
                    agentName: existing.agentName,
                    agentKind: existing.agentKind,
                    avatarUrl: existing.avatarUrl,
                    text: existing.text + (p.text ?? ""),
                    timestamp: existing.timestamp,
                    attachments: existing.attachments,
                    suggestions: existing.suggestions,
                    callActions: existing.callActions
                ))
            } else {
                let bubbleId = UUID()
                streamingBubbles[msgId] = bubbleId
                messages.append(.agent(AgentMessage(
                    id: bubbleId,
                    messageId: msgId,
                    agentName: nil,
                    agentKind: .poly,
                    avatarUrl: nil,
                    text: p.text ?? ""
                )))
            }

        case .agentLeft:
            clearTypingIndicator()

        case .liveAgentJoined(_, let a):
            clearTypingIndicator()
            if let url = a.avatarUrl { agentAvatarUrl = url }
            messages.append(.system(SystemMessage(event: .liveAgentJoined(name: a.agentName))))

        case .liveAgentMessage(_, let m):
            clearTypingIndicator()
            if let url = m.avatarUrl { agentAvatarUrl = url }
            messages.append(.agent(AgentMessage(
                messageId: m.messageId,
                agentName: m.agentName,
                agentKind: .live,
                avatarUrl: m.avatarUrl,
                text: m.text,
                attachments: m.attachments,
                suggestions: m.responseSuggestions,
                callActions: m.chatCallActions
            )))

        case .liveAgentLeft(_, let p):
            clearTypingIndicator()
            markConversationEnded(reason: p.reason)

        case .messagePending(let draftId, let text):
            messages.append(.user(UserMessage(
                text: text,
                delivery: .pending,
                draftId: draftId
            )))

        case .messageConfirmed(let draftId, _):
            updateDelivery(draftId: draftId, to: .sent)

        case .messageFailed(let draftId):
            updateDelivery(draftId: draftId, to: .failed)

        case .systemMessage(_, let s):
            messages.append(.system(SystemMessage(event: .serverMessage(text: s.message, level: s.level))))

        case .handoffQueueStatus(_, let q):
            messages.append(.system(SystemMessage(event: .queueStatus(position: q.position, displayMessage: q.displayMessage))))

        case .agentTriggeredHandoff:
            clearTypingIndicator()
            messages.append(.system(SystemMessage(event: .handoffStarted)))

        case .clientHandoffRequired(_, let p):
            clearTypingIndicator()
            let display = p.route ?? p.reason ?? ""
            messages.append(.system(SystemMessage(event: .handoffRequired(reason: display))))

        case .handoffAccepted:
            messages.append(.system(SystemMessage(event: .handoffAccepted)))

        case .handoffFailed(_, let p):
            clearTypingIndicator()
            messages.append(.system(SystemMessage(event: .handoffFailed(reason: p.reason))))

        case .handoffTimeout:
            clearTypingIndicator()
            messages.append(.system(SystemMessage(event: .handoffTimeout)))

        case .sessionIdleWarning:
            messages.append(.system(SystemMessage(event: .idleWarning)))

        case .userMessage(let env, let payload):
            // Replayed user message (session resume). Dedup on envelope.id.
            let alreadyShown = messages.contains { msg in
                if case .user(let u) = msg { return u.draftId == env.id }
                return false
            }
            if !alreadyShown {
                messages.append(.user(UserMessage(
                    text: payload.text,
                    delivery: .sent,
                    draftId: env.id
                )))
            }

        case .agentJoined(_, let a):
            if let url = a.avatarUrl { agentAvatarUrl = url }

        case .userTyping, .userEndSession,
             .requestPolyAgentJoin, .heartbeat,
             .agentMessageChunk:
            break
        }
    }

    private func markConversationEnded(reason: String?) {
        let alreadyShown = messages.contains { msg in
            if case .system(let s) = msg,
               case .conversationEnded = s.event {
                return true
            }
            return false
        }
        hasEnded = true
        guard !alreadyShown else { return }
        messages.append(.system(SystemMessage(event: .conversationEnded(reason: reason))))
    }

    /// Detects a true server-side session change (e.g. consumer-driven
    /// `startNewSession()`) and resets the conversation surface. The first
    /// non-nil sessionId we see is recorded silently — that's the natural
    /// initial assignment, not a change. Subsequent different sessionIds
    /// clear messages and latched flags. Same id is a no-op (covers WS
    /// reconnect on the same session).
    public func clearChat() {
        messages.removeAll()
        streamingBubbles.removeAll()
        hasEnded = false
        hasStarted = false
        failureReason = nil
        agentAvatarUrl = nil
        clearTypingIndicator()
    }

    private func applySessionIdChange(_ newId: String?) {
        guard let newId else { return }
        if let current = currentSessionId {
            guard newId != current else { return }
            messages.removeAll()
            hasEnded = false
            hasStarted = false
            failureReason = nil
            agentAvatarUrl = nil
            streamingBubbles.removeAll()
            clearTypingIndicator()
        }
        currentSessionId = newId
    }

    private func updateDelivery(draftId: String, to delivery: Delivery) {
        guard let idx = messages.firstIndex(where: {
            if case .user(let u) = $0 { return u.draftId == draftId }
            return false
        }) else { return }
        if case .user(var u) = messages[idx] {
            u.delivery = delivery
            messages[idx] = .user(u)
        }
    }

    // MARK: - Typing indicator

    private func startTypingIndicator() {
        typingDismissTask?.cancel()
        isAgentTyping = true
        let timeout = typingTimeout
        typingDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.isAgentTyping = false
        }
    }

    private func clearTypingIndicator() {
        typingDismissTask?.cancel()
        typingDismissTask = nil
        isAgentTyping = false
    }
}
