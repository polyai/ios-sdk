// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging

struct ChatView: View {
    static let maxMessageLength = 500

    let messages: [ChatMessage]
    let sendingLabels: Set<UUID>
    @Binding var messageText: String
    let isAgentTyping: Bool
    let agentAvatarUrl: URL?
    let chatEnded: Bool
    let isReconnecting: Bool
    let isConnected: Bool
    let isReady: Bool
    let isOnline: Bool
    let hasFailed: Bool
    var showTimestamps: Bool = false
    @FocusState.Binding var isInputFocused: Bool

    let onSend: (String) -> Void
    let onSuggestionTap: (String, UUID) -> Void
    let onRetry: (String, String?) -> Void
    let onGoBack: () -> Void
    let onEndConversation: () -> Void
    let onStartNewConversation: () -> Void
    let onTyping: () -> Void

    // F1: WhatsApp-style follow. `autoFollow` is sticky — new content scrolls to
    // the bottom while it's true, and surfaces a "New messages" pill instead while
    // it's false. ONLY the user's own dragging flips it: pulling up away from the
    // bottom stops following; scrolling back (or tapping the pill, or sending)
    // resumes it. Keeping it sticky stops a streaming reply or an in-flight scroll
    // from being misread as "the user scrolled up".
    @State private var isNearBottom = true
    @State private var hasNewBelow = false
    @State private var autoFollow = true
    @State private var userIsDragging = false
    // Timestamp of our last programmatic follow-scroll. A "far from bottom"
    // reading within a brief window after one is our own animation/streaming
    // lag; outside it, the only thing that can have moved the list is the user.
    @State private var lastFollowScrollAt = Date.distantPast

    private var inputDisabled: Bool {
        // Always allow composing while the conversation is live — offline,
        // reconnecting, or after a terminal failure (sending is optimistic).
        chatEnded
    }

    private var sendDisabled: Bool {
        inputDisabled || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if !isOnline { offlineBanner }
            if isReconnecting { reconnectingBar }
            Divider()
            if chatEnded { chatEndedBanner } else { inputBar }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if shouldShowSkeleton {
                            LoadingSkeleton()
                                .padding(.top, 4)
                                .transition(.opacity)
                                .accessibilityLabel("Loading conversation")
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let isLast = index == messages.count - 1
                            if showTimestamps,
                               MessageTimestamp.shouldInsertSeparator(
                                   previous: index > 0 ? messages[index - 1].timestamp : nil,
                                   current: message.timestamp
                               ) {
                                TimestampSeparator(date: message.timestamp)
                            }
                            MessageBubbleView(
                                message: message,
                                containerWidth: outer.size.width,
                                showSendingLabel: sendingLabels.contains(message.id),
                                showSuggestions: isLast && hasSuggestions(message) && !chatEnded,
                                showTimestamp: showTimestamps,
                                onSuggestionTap: { suggestion in
                                    onSuggestionTap(suggestion, message.id)
                                },
                                onRetry: { text, draftId in
                                    onRetry(text, draftId)
                                }
                            )
                            .id(message.id)
                        }
                        if isAgentTyping {
                            TypingIndicator(avatarUrl: agentAvatarUrl)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 16)
                                .id("typing")
                                .accessibilityLabel("Agent is typing")
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: BottomVisibleKey.self,
                                    value: g.frame(in: .named("chatScroll")).maxY
                                )
                            })
                    }
                    .padding(.vertical, 12)
                    .animation(.easeInOut(duration: 0.2), value: shouldShowSkeleton)
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(BottomVisibleKey.self) { bottomMaxY in
                    // The bottom sentinel is visible (≈ near bottom) when its maxY
                    // sits within the viewport, give or take a small threshold.
                    let near = bottomMaxY <= outer.size.height + 80
                    if near != isNearBottom { isNearBottom = near }
                    if near {
                        // Parked at the bottom (scrolled back, or our follow landed):
                        // resume following and clear the pill.
                        if !autoFollow { autoFollow = true }
                        if hasNewBelow { hasNewBelow = false }
                    } else if userIsDragging
                                || Date().timeIntervalSince(lastFollowScrollAt) > 0.3 {
                        // The user pulled up away from the bottom — either an
                        // active drag, or a "far" reading with no recent
                        // follow-scroll behind it. Transient lag while
                        // streaming/auto-scrolling stays inside the window.
                        if autoFollow { autoFollow = false }
                    }
                }
                // The SwiftUI equivalent of scrollViewWillBeginDragging: a
                // non-consuming drag that just tells us the user is scrolling.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in userIsDragging = true }
                        .onEnded { _ in userIsDragging = false }
                )
                .modifier(InteractiveKeyboardDismiss())
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Chat conversation")
                .overlay(alignment: .bottom) {
                    if hasNewBelow {
                        newMessagesPill(proxy: proxy)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onAppear {
                    // First open: land at the bottom (newest). Staggered to cover
                    // messages already present and those still streaming in.
                    for delay in [0.2, 0.5, 1.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                }
                .onChange(of: messages.count) { _ in
                    onNewContent(proxy: proxy)
                    announceLastAgentMessage()
                }
                .onChange(of: sendingLabels) { _ in
                    if autoFollow { scrollToBottom(proxy: proxy, delay: true) }
                }
                .onChange(of: isAgentTyping) { _ in
                    onNewContent(proxy: proxy)
                }
                .onChange(of: lastAgentSuggestionCount) { _ in
                    if autoFollow { scrollToBottom(proxy: proxy, delay: true) }
                }
                .onChange(of: lastAgentAttachmentCount) { _ in
                    onNewContent(proxy: proxy)
                }
                // Progressive streaming updates text in-place without changing messages.count.
                .onChange(of: lastAgentTextLength) { _ in
                    if autoFollow { scrollToBottom(proxy: proxy) } else { hasNewBelow = true }
                }
                .onChange(of: isInputFocused) { focused in
                    // Focusing to type only follows to the bottom if you were already there.
                    if focused, autoFollow { scrollToBottom(proxy: proxy, delay: true) }
                }
            }
        }
    }

    /// A new message/turn arrived: follow it only if the user is already at the
    /// bottom; otherwise leave them where they are and show the pill.
    private func onNewContent(proxy: ScrollViewProxy) {
        if autoFollow {
            scrollToBottom(proxy: proxy)
            scrollToBottom(proxy: proxy, delay: true)
        } else {
            hasNewBelow = true
        }
    }

    private func newMessagesPill(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            hasNewBelow = false
            isNearBottom = true
            autoFollow = true
        } label: {
            Label("New messages", systemImage: "arrow.down")
                .font(.caption.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.blue))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .accessibilityLabel("Scroll to newest messages")
    }

    private var shouldShowSkeleton: Bool {
        messages.isEmpty && !isAgentTyping && !chatEnded && !hasFailed
    }

    private func announceLastAgentMessage() {
        guard case .agent(let m) = messages.last, !m.text.isEmpty else { return }
        let prefix = m.agentName.map { "\($0) says: " } ?? "Agent says: "
        UIAccessibility.post(notification: .announcement, argument: prefix + m.text)
    }

    private func hasSuggestions(_ message: ChatMessage) -> Bool {
        !message.suggestions.isEmpty
    }

    private var lastAgentSuggestionCount: Int {
        messages.last?.suggestions.count ?? 0
    }

    private var lastAgentTextLength: Int {
        messages.last?.text?.count ?? 0
    }

    private var lastAgentAttachmentCount: Int {
        messages.last?.attachments.count ?? 0
    }

    // MARK: - Bottom bars

    private var reconnectingBar: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Reconnecting...").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.systemYellow).opacity(0.15))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnecting")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("You're offline").font(.caption.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.systemRed).opacity(0.18))
        .foregroundColor(.red)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You're offline. Messages will not be delivered until the connection is restored.")
    }

    private var chatEndedBanner: some View {
        VStack(spacing: 10) {
            Text("This conversation has ended. Please start a new chat to continue.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button { onStartNewConversation() } label: {
                Text("Start New Conversation").font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.vertical, 12).frame(maxWidth: .infinity).background(.bar)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            composerField
                .accessibilityIdentifier("composer")
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .disabled(inputDisabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityHint(inputDisabled ? "Input disabled. \(disabledReason)" : "Type a message")

            Button {
                let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                messageText = ""
                if !trimmed.isEmpty {
                    autoFollow = true   // follow the agent's reply while we wait
                    onSend(trimmed)
                }
                isInputFocused = true
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(sendDisabled ? .gray : .blue)
            }
            .disabled(sendDisabled)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
    }

    // F4: a composer that grows 1–5 lines on iOS 16+ (web parity); single-line
    // fallback on iOS 15. Return sends in both cases (newlines arrive via paste).
    @ViewBuilder
    private var composerField: some View {
        if #available(iOS 16.0, *) {
            TextField("Message...", text: $messageText, axis: .vertical)
                .lineLimit(1...5)
                .onChange(of: messageText) { handleComposerChange($0) }
        } else {
            TextField("Message...", text: $messageText)
                .submitLabel(.send)
                .onChange(of: messageText) { newValue in
                    if newValue.count > Self.maxMessageLength {
                        messageText = String(newValue.prefix(Self.maxMessageLength))
                    }
                    if !newValue.isEmpty { onTyping() }
                }
                .onSubmit { submitFromReturn() }
        }
    }

    /// iOS 16+ growing field: Return inserts '\n', so detect a trailing newline and
    /// treat it as a send; otherwise enforce the length cap and broadcast typing.
    private func handleComposerChange(_ newValue: String) {
        if newValue.hasSuffix("\n") {
            submitFromReturn(raw: newValue)
            return
        }
        if newValue.count > Self.maxMessageLength {
            messageText = String(newValue.prefix(Self.maxMessageLength))
        }
        if !newValue.isEmpty { onTyping() }
    }

    private func submitFromReturn(raw: String? = nil) {
        let trimmed = (raw ?? messageText).trimmingCharacters(in: .whitespacesAndNewlines)
        messageText = ""
        if !inputDisabled, !trimmed.isEmpty {
            autoFollow = true   // follow the agent's reply while we wait
            onSend(trimmed)
        }
        DispatchQueue.main.async { isInputFocused = true }
    }

    private var disabledReason: String {
        if !isOnline { return "You're offline." }
        if hasFailed { return "Connection failed. Pull to retry." }
        if !isConnected { return "Connecting…" }
        if !isReady { return "Session not ready." }
        if chatEnded { return "Chat ended." }
        return ""
    }

    // MARK: - Scroll

    private func scrollToBottom(proxy: ScrollViewProxy, delay: Bool = false) {
        let doScroll = {
            lastFollowScrollAt = Date()
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        let initial = delay ? 0.15 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + initial) { doScroll() }
    }
}

/// Reports the bottom sentinel's maxY within the scroll viewport so the view can
/// tell whether the user is parked near the bottom.
private struct BottomVisibleKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
