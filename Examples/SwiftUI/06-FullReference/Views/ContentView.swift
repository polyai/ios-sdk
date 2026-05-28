// Copyright PolyAI Limited

import SwiftUI
import PolyMessaging

/// Minimal-but-real PolyMessaging integration. The flow is the same one a
/// production app would ship: configure → resume-or-start → chat → end. No
/// debug surfaces. See ../07-Playground for the developer playground
/// (settings sheet, diagnostics, live actions, etc.).

enum AppScreen: Equatable {
    case connect
    case loading
    case chat
    case error(message: String)

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

struct ContentView: View {
    @State private var screen: AppScreen = .connect
    @State private var messageText = ""
    @State private var session: ChatSession?
    @State private var wasResumed: Bool = false
    @State private var showEndConfirm = false
    @StateObject private var reachability = NetworkMonitor()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationView {
            currentScreen
                .navigationTitle("PolyMessaging")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarItems }
                .alert("End Conversation", isPresented: $showEndConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("End Conversation", role: .destructive) { endConversation() }
                } message: {
                    Text("This will permanently end the current conversation. You won't be able to resume it.")
                }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch screen {
        case .connect:
            ConnectView(
                hasActiveSession: session != nil,
                canResume: PolyMessaging.hasResumableSession(),
                onResume: { configureAndStart(forceFresh: false) },
                onStartNew: { configureAndStart(forceFresh: true) }
            )
        case .loading:
            LoadingView()
        case .chat:
            if let session {
                ChatScreen(
                    session: session,
                    messageText: $messageText,
                    isInputFocused: $isInputFocused,
                    isOnline: reachability.isOnline,
                    wasResumed: wasResumed,
                    onSend: { send($0) },
                    onPause: { screen = .connect },
                    onEndConversation: { showEndConfirm = true },
                    onStartNewConversation: { startNewConversationInPlace() }
                )
            }
        case .error(let msg):
            ErrorScreen(message: msg, onBack: { screen = .connect })
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if screen != .connect {
                Button { screen = .connect } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if screen != .connect {
                Button(role: .destructive) { showEndConfirm = true } label: {
                    Image(systemName: "xmark.circle")
                }
                .accessibilityLabel("End Conversation")
            }
        }
    }

    // MARK: - SDK lifecycle

    private func configureAndStart(forceFresh: Bool) {
        if let existing = session {
            if forceFresh {
                screen = .loading
                wasResumed = false
                session = ChatSession(client: existing.client)
                Task {
                    do { try await existing.client.startNewSession() }
                    catch {
                        // use String(describing:) for the actual case text.
                        screen = .error(message: "Couldn't start a new session.\n\(String(describing: error))")
                    }
                }
            } else {
                screen = .chat
            }
            return
        }

        // The connection config was set once in FullReferenceApp.init via
        // initialize(...); the no-arg facade reuses it. Resume vs start-fresh
        // is the only difference here.
        let s = forceFresh
            ? PolyMessaging.start()
            : PolyMessaging.chat()
        session = s
        wasResumed = false
        screen = .loading

        let client = s.client
        Task {
            for await event in client.events {
                if case .sessionStart = event, screen == .loading {
                    screen = .chat
                }
                if case .disconnected(let err) = event,
                   let err, screen == .loading {
                    screen = .error(message: "Couldn't connect.\n\(err)")
                }
            }
        }
        Task {
            for await status in client.connectionStatus {
                if case .failed(let reason) = status, screen == .loading {
                    let message = reason.map { String(describing: $0) } ?? "Unknown failure"
                    screen = .error(message: "Connection failed.\n\(message)")
                }
            }
        }
        Task {
            for await state in client.sessionState {
                if state.status == .restored {
                    wasResumed = true
                }
                if state.isReady, screen == .loading || screen.isError {
                    screen = .chat
                }
                if state.isError, screen == .loading {
                    screen = .error(message: state.errorMessage ?? "Couldn't start the session.")
                }
            }
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        messageText = ""
        let s = session
        Task {
            try? await s?.send(trimmed)
        }
    }

    private func endConversation() {
        let pending = session
        Task {
            try? await pending?.end()
            session = nil
            wasResumed = false
            screen = .connect
        }
    }

    private func startNewConversationInPlace() {
        guard let s = session else { return }
        s.clearChat()
        Task {
            try? await s.client.startNewSession()
        }
    }
}

// MARK: - Chat screen wrapper

private struct ChatScreen: View {
    @ObservedObject var session: ChatSession
    @Binding var messageText: String
    @FocusState.Binding var isInputFocused: Bool
    let isOnline: Bool
    let wasResumed: Bool
    let onSend: (String) -> Void
    let onPause: () -> Void
    let onEndConversation: () -> Void
    let onStartNewConversation: () -> Void

    @State private var sendingLabels: Set<UUID> = []
    @State private var trackedPending: Set<UUID> = []
    @State private var showResumeBanner: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if showResumeBanner { resumeBanner }

            ChatView(
                messages: session.messages,
                sendingLabels: sendingLabels,
                messageText: $messageText,
                isAgentTyping: session.isAgentTyping,
                agentAvatarUrl: session.agentAvatarUrl,
                chatEnded: session.hasEnded,
                isReconnecting: session.connection.isReconnecting,
                isConnected: session.connection.isConnected,
                isReady: session.isReady,
                // OR with isConnected: NWPathMonitor can briefly report "unsatisfied" during VPN flicker.
                isOnline: isOnline || session.connection.isConnected,
                hasFailed: session.connection.isFailed,
                isInputFocused: $isInputFocused,
                onSend: onSend,
                onSuggestionTap: { text, id in
                    session.clearSuggestions(for: id)
                    onSend(text)
                },
                onRetry: { text, draftId in
                    if let draftId { session.removeMessage(draftId: draftId) }
                    onSend(text)
                },
                onGoBack: onPause,
                onEndConversation: onEndConversation,
                onStartNewConversation: onStartNewConversation,
                onTyping: { Task { await session.sendTyping() } }
            )
        }
        .onReceive(session.$messages) { syncSendingLabels($0) }
        .onAppear {
            if wasResumed {
                showResumeBanner = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { showResumeBanner = false }
                }
            }
        }
    }

    private var resumeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
            Text("Resumed previous conversation")
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.85))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Delays the "Sending..." label by 500ms so fast confirmations don't flash it.
    private func syncSendingLabels(_ messages: [ChatMessage]) {
        for case .user(let u) in messages where u.delivery == .pending && !trackedPending.contains(u.id) {
            trackedPending.insert(u.id)
            let id = u.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard case .user(let current) = session.messages.first(where: { $0.id == id }),
                      current.delivery == .pending else { return }
                sendingLabels.insert(id)
            }
        }
        let stillPending: Set<UUID> = Set(messages.compactMap {
            if case .user(let u) = $0, u.delivery == .pending { return u.id }
            return nil
        })
        sendingLabels.formIntersection(stillPending)
        trackedPending.formIntersection(stillPending)
    }
}
