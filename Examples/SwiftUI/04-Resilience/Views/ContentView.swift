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
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

struct ContentView: View {
    // @StateObject survives view re-renders — one ChatSession per chat surface.
    @StateObject var session = PolyMessaging.chat()
    @StateObject var network = NetworkMonitor()
    @State private var input = ""

    private var sendDisabled: Bool {
        input.trimmingCharacters(in: .whitespaces).isEmpty || session.hasEnded
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
                            }
                        }
                        // Horizontal padding lives on each bubble's outer
                        // HStack (MessageBubbleView). Keeping it here would
                        // double-pad the row in landscape.
                        .padding(.vertical, 8)
                    }
                }
                .modifier(InteractiveKeyboardDismiss())
                .onChange(of: session.messages.count) { _ in
                    if let last = session.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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

    private func send() {
        let text = input
        input = ""
        Task { try? await session.send(text) }
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
        HStack(spacing: 12) {
            TextField("Message...", text: $input)
                .accessibilityIdentifier("composer")
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onChange(of: input) { _ in Task { await session.sendTyping() } }
                .onSubmit { send() }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.systemGray6)).clipShape(Capsule())
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(sendDisabled ? .gray : .blue)
            }
            .disabled(sendDisabled)
        }
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
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
