// Copyright PolyAI Limited

//  ContentView.swift
//  Examples/SwiftUI/02-Standard
//
//  Mirrors README:
//    - § "Use in your app > SwiftUI"
//    - § "Best practices > Render reconnects as a banner"
//    - § "Best practices > Surface .failed with a manual retry"
//    - § "Best practices > Trust the typing throttle"
//    - § "Best practices > Handle keyboard yourself"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

struct ContentView: View {
    // @StateObject survives view re-renders — one ChatSession per chat surface.
    @StateObject var session = PolyMessaging.chat()
    @State private var input = ""

    private var sendDisabled: Bool {
        input.trimmingCharacters(in: .whitespaces).isEmpty || session.hasEnded
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ConnectionBanner(status: session.connection)

                ScrollViewReader { proxy in
                    ScrollView {
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
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

    @ViewBuilder
    private var failureOverlay: some View {
        if let reason = session.failureReason {
            VStack(spacing: 12) {
                Text("Connection lost")
                    .font(.headline)
                // PolyError isn't LocalizedError, so .localizedDescription
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
