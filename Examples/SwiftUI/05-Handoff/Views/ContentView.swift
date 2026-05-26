// Copyright PolyAI Limited

//  ContentView.swift
//  Examples/SwiftUI/05-Handoff
//
//  Mirrors README:
//    - § "Use in your app > SwiftUI"
//    - § "What you can build > Live agent handoff"
//    - § "Get started > Listen for events"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import UIKit
import PolyMessaging

struct ContentView: View {
    // @StateObject survives view re-renders — one ChatSession per chat surface.
    @StateObject var session = PolyMessaging.chat()
    @StateObject private var network = NetworkMonitor()
    @State private var input = ""

    @State private var connectedAgentName: String? = nil

    private var sendDisabled: Bool {
        input.trimmingCharacters(in: .whitespaces).isEmpty || session.hasEnded
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                OfflineBanner(isOnline: network.isOnline)
                ConnectionBanner(status: session.connection)

                ScrollViewReader { proxy in
                    ScrollView {
                        if session.messages.isEmpty && !session.hasEnded {
                            LoadingSkeleton().padding(.top, 24)
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
                            .padding(.horizontal, 12)
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
            .navigationTitle(navigationTitle)
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
            // Subscribe to raw events. README "Listen for events > SwiftUI"
            // pattern: .task { for await event in session.client.events }.
            // Cancelled automatically when the view leaves the hierarchy.
            .task {
                for await event in session.client.events {
                    handle(event: event)
                }
            }
        }
    }

    // MARK: - Event handling

    private func handle(event: MessagingEvent) {
        switch event {
        case .liveAgentJoined(_, let p):
            connectedAgentName = p.agentName

        case .clientHandoffRequired(_, let p):
            // Optionally deep-link to the route URL if it parses.
            if let route = p.route, let url = URL(string: route),
               let scheme = url.scheme, scheme.hasPrefix("http") {
                UIApplication.shared.open(url)
            }

        case .liveAgentLeft:
            connectedAgentName = nil

        case .sessionStart:
            connectedAgentName = nil

        default:
            // Handoff progress events flow through session.messages as
            // SystemMessage pills. liveAgentTyping is handled by
            // session.isAgentTyping, and liveAgentMessage flows into
            // session.messages as an AgentMessage with agentKind = .live.
            break
        }
    }

    private var navigationTitle: String {
        if let name = connectedAgentName, !name.isEmpty { return name }
        return "Chat"
    }

    /// True when the most recent system message is a liveAgentLeft.
    private var liveChatJustEnded: Bool {
        for case .system(let m) in session.messages.reversed() {
            // First (most-recent) system message wins; return immediately.
            if case .liveAgentLeft = m.event { return true } else { return false }
        }
        return false
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

    // MARK: - Subviews

    private var chatEndedFooter: some View {
        VStack(spacing: 10) {
            Text(liveChatJustEnded
                 ? "This live chat has ended. Please start a new chat to continue."
                 : "This conversation has ended. Please start a new chat to continue.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button {
                connectedAgentName = nil
                Task { try? await session.client.startNewSession() }
            } label: {
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
                Text("Connection lost").font(.headline)
                // PolyError isn't LocalizedError, so .localizedDescription
                // falls back to Error's generic default. Use String(describing:).
                Text(String(describing: reason))
                    .font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary)
                Button("Reconnect") { Task { try? await session.client.resume() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(32)
        }
    }
}

// `scrollDismissesKeyboard` requires iOS 16. Wrap with an availability check
// so the example still compiles on iOS 15 (the SDK's minimum).
private struct InteractiveKeyboardDismiss: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}
