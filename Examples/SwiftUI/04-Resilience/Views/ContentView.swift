// Copyright PolyAI Limited

//  ContentView.swift
//  Examples/SwiftUI/04-Resilience
//
//  Mirrors README:
//    - § "Use in your app > SwiftUI"
//    - § "What you can build > Connection monitoring"
//    - § "Best practices > Render reconnects as a banner"
//    - § "Best practices > Surface .failed with a manual retry"
//

import SwiftUI
import PolyMessaging

struct ContentView: View {
    static let maxMessageLength = 500

    // @StateObject survives view re-renders — one ChatSession per chat surface.
    @StateObject var session = PolyMessaging.chat()
    @StateObject var network = NetworkMonitor()
    @State private var input = ""
    @FocusState private var isInputFocused: Bool

    // F1: only auto-scroll when the user is already near the bottom; otherwise
    // surface a "New messages" pill instead of yanking them away from history.
    @State private var isNearBottom = true
    @State private var hasNewBelow = false

    private var sendDisabled: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasEnded
    }

    var body: some View {
        NavigationView {
            Group {
                // Terminal state: SDK has exhausted its reconnect budget.
                // Replace the entire chat UI with a full-screen retry CTA.
                if let reason = session.failureReason {
                    TerminalErrorScreen(reason: reason) {
                        Task { try? await session.client.resume() }
                    }
                } else {
                    mainChat
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !session.hasEnded && session.failureReason == nil {
                        Button("End Chat") {
                            Task { try? await session.end() }
                        }
                    }
                }
            }
        }
        // Force single-column stack style. The legacy NavigationView defaults
        // to split-view in landscape on regular-width devices (iPad / Plus /
        // Max in landscape), which collapses the chat into the detail pane
        // and hides the sidebar. Use NavigationStack on iOS 16+ when we
        // raise the deployment target. (Examples target iOS 15.)
        .navigationViewStyle(.stack)
    }

    private var mainChat: some View {
        VStack(spacing: 0) {
            // OS-level offline pill. Stacks above the SDK's own reconnect
            // banner — both can be visible simultaneously.
            OfflineBanner(isOnline: network.isOnline)
            ConnectionBanner(status: session.connection)

            GeometryReader { outer in
                ScrollViewReader { proxy in
                    ScrollView {
                        // Pre-handshake: show skeleton until isReady flips or
                        // the first message lands.
                        if !session.isReady && session.messages.isEmpty {
                            LoadingSkeleton()
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(session.messages) { message in
                                    MessageBubbleView(
                                        message: message,
                                        containerWidth: outer.size.width,
                                        onRetry: { text in Task { try? await session.send(text) } },
                                        showSendingLabel: showSendingLabel(for: message),
                                        // Pills attach under the last message and clear
                                        // as soon as the user sends (mirrors 06).
                                        showSuggestions: !session.hasEnded && message.id == session.messages.last?.id,
                                        onSuggestionTap: { text in
                                            session.clearSuggestions(for: message.id)
                                            Task { try? await session.send(text) }
                                        }
                                    )
                                    .id(message.id)
                                }
                                if session.isAgentTyping {
                                    TypingIndicator(avatarUrl: session.lastAgentMessage?.avatarUrl)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        // Match each message bubble's .padding(.horizontal)
                                        // so the typing avatar lines up with the agent
                                        // message avatars instead of hugging the far edge.
                                        .padding(.horizontal)
                                }
                                // Stable scroll anchor — avoids off-by-one when LazyVStack
                                // hasn't laid out new bubbles yet, and reports whether the
                                // user is parked near the bottom (F1).
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
                            // Horizontal padding lives on each bubble's outer
                            // HStack (MessageBubbleView). Keeping it here would
                            // double-pad the row in landscape.
                            .padding(.vertical, 8)
                        }
                    }
                    .coordinateSpace(name: "chatScroll")
                    .onPreferenceChange(BottomVisibleKey.self) { bottomMaxY in
                        let near = bottomMaxY <= outer.size.height + 80
                        if near != isNearBottom { isNearBottom = near }
                        if near, hasNewBelow { hasNewBelow = false }
                    }
                    .modifier(InteractiveKeyboardDismiss())
                    .overlay(alignment: .bottom) {
                        if hasNewBelow {
                            newMessagesPill(proxy: proxy)
                                .padding(.bottom, 10)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onChange(of: session.messages.count) { _ in
                        onNewContent(proxy)
                    }
                    // Streaming grows the last agent message's text in place without
                    // changing messages.count, so also follow its length — otherwise
                    // the view stops scrolling mid-stream (mirrors 06-FullReference).
                    .onChange(of: session.lastAgentMessage?.text.count) { _ in
                        onNewContent(proxy)
                    }
                }
            }

            if session.hasEnded {
                chatEndedFooter
            } else {
                inputBar
            }
        }
    }

    private func showSendingLabel(for message: ChatMessage) -> Bool {
        if case .user(let m) = message, m.delivery == .pending { return true }
        return false
    }

    /// New content arrived: follow it only if the user is already at the bottom;
    /// otherwise leave them where they are and show the pill (F1).
    private func onNewContent(_ proxy: ScrollViewProxy) {
        if isNearBottom {
            scrollToBottom(proxy)
        } else {
            hasNewBelow = true
        }
    }

    /// Keep the newest message pinned to the bottom. Re-runs after a short delay
    /// so it catches the layout settling as a streaming bubble grows taller.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let doScroll = { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        doScroll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { doScroll() }
    }

    private func newMessagesPill(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            hasNewBelow = false
            isNearBottom = true
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

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        if !session.hasEnded, !text.isEmpty { Task { try? await session.send(text) } }
        isInputFocused = true
    }

    private var chatEndedFooter: some View {
        VStack(spacing: 10) {
            Text("This conversation has ended. Please start a new chat to continue.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button { Task { try? await session.client.startNewSession() } } label: {
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
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 18))
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(sendDisabled ? .gray : .blue)
            }
            .disabled(sendDisabled)
        }
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
    }

    // F4: a composer that grows 1–5 lines on iOS 16+ (web parity); single-line
    // fallback on iOS 15. Return sends in both cases (newlines arrive via paste).
    @ViewBuilder
    private var composerField: some View {
        if #available(iOS 16.0, *) {
            TextField("Message...", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .onChange(of: input) { handleComposerChange($0) }
        } else {
            TextField("Message...", text: $input)
                .submitLabel(.send)
                .onChange(of: input) { newValue in
                    if newValue.count > Self.maxMessageLength {
                        input = String(newValue.prefix(Self.maxMessageLength))
                    }
                    if !newValue.isEmpty { Task { await session.sendTyping() } }
                }
                .onSubmit { send() }
        }
    }

    /// iOS 16+ growing field: Return inserts '\n', so detect a trailing newline and
    /// treat it as a send; otherwise enforce the length cap and broadcast typing.
    private func handleComposerChange(_ newValue: String) {
        if newValue.hasSuffix("\n") {
            send()
            return
        }
        if newValue.count > Self.maxMessageLength {
            input = String(newValue.prefix(Self.maxMessageLength))
        }
        if !newValue.isEmpty { Task { await session.sendTyping() } }
    }
}

/// Reports the bottom sentinel's maxY within the scroll viewport so the view can
/// tell whether the user is parked near the bottom (F1).
private struct BottomVisibleKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// `scrollDismissesKeyboard` requires iOS 16. Wrap with an availability check so
// the example still compiles on iOS 15 (the SDK's minimum).
private struct InteractiveKeyboardDismiss: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}
