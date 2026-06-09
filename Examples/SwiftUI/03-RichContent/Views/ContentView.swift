// Copyright PolyAI Limited

//  ContentView.swift
//  Examples/SwiftUI/03-RichContent
//
//  Mirrors README:
//    - § "Use in your app > SwiftUI"
//    - § "Best practices > Trust the typing throttle"
//    - § "Best practices > Handle keyboard yourself"
//

import SwiftUI
import PolyMessaging

struct ContentView: View {
    static let maxMessageLength = 500

    // @StateObject survives view re-renders — one ChatSession per chat surface.
    @StateObject var session = PolyMessaging.chat()
    @State private var input = ""

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

    private var sendDisabled: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasEnded
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ConnectionBanner(status: session.connection)

                GeometryReader { outer in
                    ScrollViewReader { proxy in
                        ScrollView {
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
                                // Stable scroll anchor — avoids off-by-one when the
                                // LazyVStack hasn't laid out new bubbles yet, and lets
                                // us measure how close the user is to the bottom.
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
                        .coordinateSpace(name: "chatScroll")
                        .onPreferenceChange(BottomVisibleKey.self) { bottomMaxY in
                            let near = bottomMaxY <= outer.size.height + 80
                            if near != isNearBottom { isNearBottom = near }
                            if near {
                                // Parked at the bottom (scrolled back, or our follow
                                // landed): resume following and clear the pill.
                                if !autoFollow { autoFollow = true }
                                if hasNewBelow { hasNewBelow = false }
                            } else if userIsDragging {
                                // Only a real drag away from the bottom stops following —
                                // not transient lag while streaming or auto-scrolling.
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
                        .onChange(of: session.isAgentTyping) { _ in
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
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !session.hasEnded {
                        Button("End Chat") {
                            Task { try? await session.end() }
                        }
                    }
                }
            }
            .overlay(failureOverlay)
        }
        // Force single-column stack style. The legacy NavigationView defaults
        // to split-view in landscape on regular-width devices (iPad / Plus /
        // Max in landscape), which collapses the chat into the detail pane
        // and hides the sidebar. Use NavigationStack on iOS 16+ when we
        // raise the deployment target. (Examples target iOS 15.)
        .navigationViewStyle(.stack)
        // New-message banners (foreground + grace window) — see NewMessageNotifier.swift
        .newMessageNotifications(for: session)
    }

    private func showSendingLabel(for message: ChatMessage) -> Bool {
        if case .user(let m) = message, m.delivery == .pending { return true }
        return false
    }

    /// New content arrived: follow it only if the user is already at the bottom;
    /// otherwise leave them where they are and surface the "New messages" pill.
    private func onNewContent(_ proxy: ScrollViewProxy) {
        if autoFollow {
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

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        if !session.hasEnded, !trimmed.isEmpty {
            autoFollow = true   // follow the agent's reply while we wait
            Task { try? await session.send(trimmed) }
        }
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
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 20))
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
                    Task { await session.sendTyping() }
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
        Task { await session.sendTyping() }
    }

    @ViewBuilder
    private var failureOverlay: some View {
        if let reason = session.failureReason {
            VStack(spacing: 12) {
                Text("Connection lost")
                    .font(.headline)
                // falls back to Error's generic default. Use String(describing:).
                Text(String(describing: reason))
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Button("Reconnect") {
                    Task { try? await session.client.resume() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(32)
        }
    }
}

// `scrollDismissesKeyboard` requires iOS 16. Wrap with an availability check so
// the example still compiles on iOS 15 (the SDK's minimum). README's Best
// Practices "Handle keyboard yourself" snippet calls out the version gate.
private struct InteractiveKeyboardDismiss: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}

/// Reports the bottom sentinel's maxY within the scroll viewport so the view can
/// tell whether the user is parked near the bottom (F1 gated auto-scroll).
private struct BottomVisibleKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
