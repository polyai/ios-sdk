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
    @FocusState.Binding var isInputFocused: Bool

    let onSend: (String) -> Void
    let onSuggestionTap: (String, UUID) -> Void
    let onRetry: (String, String?) -> Void
    let onGoBack: () -> Void
    let onEndConversation: () -> Void
    let onStartNewConversation: () -> Void
    let onTyping: () -> Void

    private var inputDisabled: Bool {
        // Always allow composing while the conversation is live — offline,
        // reconnecting, or after a terminal failure (sending is optimistic).
        chatEnded
    }

    private var sendDisabled: Bool {
        inputDisabled || messageText.trimmingCharacters(in: .whitespaces).isEmpty
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
                        MessageBubbleView(
                            message: message,
                            showSendingLabel: sendingLabels.contains(message.id),
                            showSuggestions: isLast && hasSuggestions(message) && !chatEnded,
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
                    // Stable scroll anchor — avoids off-by-one when LazyVStack hasn't laid out new bubbles yet.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 12)
                .animation(.easeInOut(duration: 0.2), value: shouldShowSkeleton)
            }
            .modifier(InteractiveKeyboardDismiss())
            // Region + explicit announcements instead of role="log" (VoiceOver compat).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chat conversation")
            .onAppear {
                // Staggered scrolls: messages may already exist or still be streaming in when we mount.
                for delay in [0.2, 0.5, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: messages.count) { _ in
                scrollToBottom(proxy: proxy)
                scrollToBottom(proxy: proxy, delay: true)
                announceLastAgentMessage()
            }
            .onChange(of: sendingLabels) { _ in
                scrollToBottom(proxy: proxy, delay: true)
            }
            .onChange(of: isAgentTyping) { typing in
                if typing { scrollToBottom(proxy: proxy) }
                else { scrollToBottom(proxy: proxy, delay: true) }
            }
            .onChange(of: lastAgentSuggestionCount) { _ in
                scrollToBottom(proxy: proxy, delay: true)
            }
            .onChange(of: lastAgentAttachmentCount) { _ in
                scrollToBottom(proxy: proxy, delay: true)
            }
            // Streaming updates text in place without changing messages.count, so track length too.
            .onChange(of: lastAgentTextLength) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: isInputFocused) { focused in
                if focused {
                    scrollToBottom(proxy: proxy, delay: true)
                }
            }
        }
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
        HStack(spacing: 12) {
            TextField("Message...", text: $messageText)
                .accessibilityIdentifier("composer")
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .submitLabel(.send)
                .disabled(inputDisabled)
                .onChange(of: messageText) { newValue in
                    if newValue.count > Self.maxMessageLength {
                        messageText = String(newValue.prefix(Self.maxMessageLength))
                    }
                    // Safe on every keystroke — SDK throttles internally.
                    if !newValue.isEmpty {
                        onTyping()
                    }
                }
                .onSubmit {
                    guard !sendDisabled else { return }
                    onSend(messageText)
                    DispatchQueue.main.async { isInputFocused = true }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.systemGray6)).clipShape(Capsule())
                .accessibilityHint(inputDisabled ? "Input disabled. \(disabledReason)" : "Type a message")

            Button {
                onSend(messageText)
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
            withAnimation {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        let initial = delay ? 0.15 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + initial) { doScroll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doScroll() }
    }
}
