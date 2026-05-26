import SwiftUI
import PolyMessaging

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
    @State private var logs: [LogEntry] = []
    @State private var session: ChatSession?
    @State private var wasResumed: Bool = false
    @State private var showLogs = false
    @State private var showEndConfirm = false
    @State private var showSettings = false
    @StateObject private var reachability = NetworkMonitor()
    @StateObject private var devSettings = DevSettings()
    @StateObject private var diagnostics = DevDiagnostics()
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
                .sheet(isPresented: $showLogs) { LogsSheet(logs: logs) }
                .sheet(isPresented: $showSettings) {
                    SettingsSheet(
                        settings: devSettings,
                        diagnostics: diagnostics,
                        hasLiveSession: session != nil,
                        hasResumableSession: PolyMessaging.hasResumableSession(),
                        onApplyAndRestart: { applySettingsAndRestart() },
                        onForceReconnect: { forceReconnect() },
                        onSimulateDrop: { simulateNetworkDrop() },
                        onDisconnectClean: { closeWith(code: 1000, reason: "Debug clean disconnect") },
                        onSimulateServerReject: { closeWith(code: 4001, reason: "Debug server-reject simulation") },
                        onSimulateIdleTimeout: { closeWith(code: 4002, reason: "Debug idle-timeout simulation") },
                        onSendHeartbeat: { rawSend(.heartbeat) },
                        onSendTypingStart: { rawSend(.userTyping(.started)) },
                        onSendTypingStop: { rawSend(.userTyping(.stopped)) },
                        onSendUserEndSession: { rawSend(.userEndConversation) },
                        onSendUserLeft: { rawSend(.userLeft) }
                    )
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
                hasCustomSettings: devSettings.hasCustomization,
                environmentLabel: devSettings.environmentDisplayName(),
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
                    showDebugStrip: devSettings.showDebugStrip,
                    showTimestamps: devSettings.showMessageTimestamps,
                    diagnostics: diagnostics,
                    onSend: { send($0) },
                    onLog: { log($0) },
                    onPause: { pauseAndGoBack() },
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
                Button { pauseAndGoBack() } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if screen != .connect {
                Menu {
                    Button {
                        showLogs = true
                    } label: {
                        Label("View Logs", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Label("Dev Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showEndConfirm = true
                    } label: {
                        Label("End Conversation", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Dev Settings")
            }
        }
    }

    // MARK: - Actions

    private func configureAndStart(forceFresh: Bool) {
        if let existing = session {
            if forceFresh {
                screen = .loading
                wasResumed = false
                session = ChatSession(client: existing.client)
                logs.removeAll()
                log("Ending current session and starting fresh...")
                Task {
                    do {
                        try await existing.client.startNewSession()
                    } catch {
                        log("Start new failed: \(error)")
                        // The SDK throws PolyError, which isn't LocalizedError —
                        // use String(describing:) for the actual case text.
                        screen = .error(message: "Couldn't start a new session.\n\(String(describing: error))")
                    }
                }
            } else {
                screen = .chat
            }
            return
        }

        let config = devSettings.buildConfiguration()
        let streaming = devSettings.progressiveStreaming
        let s = forceFresh
            ? PolyMessaging.start(config, progressiveStreaming: streaming)
            : PolyMessaging.chat(config, progressiveStreaming: streaming)
        diagnostics.attach(to: s.client)
        session = s
        wasResumed = false
        screen = .loading
        log(forceFresh ? "Starting new session..." : "Resuming session...")

        let client = s.client
        Task {
            for await event in client.events {
                if shouldLog(event) {
                    logs.append(EventLogger.makeEntry(event: event))
                }
                if case .sessionStart = event, screen == .loading {
                    screen = .chat
                }
                if case .disconnected(let err) = event,
                   let err,
                   screen == .loading {
                    screen = .error(message: "Couldn't connect.\n\(err)")
                }
            }
        }
        Task {
            for await status in client.connectionStatus {
                log("Connection: \(status)")
                if case .failed(let reason) = status, screen == .loading {
                    screen = .error(message: "Connection failed.\n\(reason)")
                }
            }
        }

        Task {
            var observedFirstSessionId: String? = nil
            for await state in client.sessionState {
                if state.status == .restored {
                    wasResumed = true
                    log("Resumed previous conversation")
                }
                if state.isReady, screen == .loading || screen.isError {
                    screen = .chat
                }
                if state.isReady, let sid = state.sessionId,
                   observedFirstSessionId == nil, !wasResumed {
                    observedFirstSessionId = sid
                    devSettings.recordSessionApplied()
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
            do { try await s?.send(trimmed) }
            catch { log("Send failed: \(error)") }
        }
    }

    private func pauseAndGoBack() {
        screen = .connect
    }

    /// Awaits `end()` before navigating so `hasResumableSession` doesn't show a phantom "Resume" button.
    private func endConversation() {
        let pending = session
        Task {
            try? await pending?.end()
            session = nil
            wasResumed = false
            logs.removeAll()
            diagnostics.reset()
            screen = .connect
        }
    }

    /// Bypasses SDK dedup/throttle layers via `getConnection()` for protocol-level testing.
    private func rawSend(_ event: OutgoingEvent) {
        guard let c = session?.client else { return }
        log("Debug send: \(event)")
        Task {
            await c.getConnection().send(event)
            diagnostics.recordOutgoing()
        }
    }

    private func forceReconnect() {
        guard let c = session?.client else { return }
        log("Debug: force reconnect (synthesizing 1006)")
        Task {
            await c.getConnection().disconnect(code: 1006, reason: "Debug force reconnect")
        }
    }

    private func simulateNetworkDrop() {
        guard let c = session?.client else { return }
        log("Debug: simulating network drop")
        Task {
            await c.getConnection().disconnect(code: 1006, reason: "Debug simulated drop")
        }
    }

    private func closeWith(code: Int, reason: String) {
        guard let c = session?.client else { return }
        log("Debug: close with code \(code) — \(reason)")
        Task {
            await c.getConnection().disconnect(code: code, reason: reason)
        }
    }

    private func applySettingsAndRestart() {
        let pending = session
        Task {
            try? await pending?.end()
            await pending?.client.shutdown()
            session = nil
            wasResumed = false
            logs.removeAll()
            diagnostics.reset()
            screen = .loading
            devSettings.recordSessionApplied()
            configureAndStart(forceFresh: true)
        }
    }

    private func startNewConversationInPlace() {
        guard let s = session else { return }
        log("Starting new conversation in place...")
        s.clearChat()
        Task {
            do {
                try await s.client.startNewSession()
            } catch {
                log("Start new failed: \(error)")
            }
        }
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        logs.append(EventLogger.makeEntry(msg))
    }

    private func shouldLog(_ event: MessagingEvent) -> Bool {
        switch event {
        case .messagePending, .messageConfirmed, .messageFailed,
             .heartbeat, .userTyping, .userEndSession, .requestPolyAgentJoin:
            return false
        default:
            return true
        }
    }
}

// MARK: - Chat screen

private struct ChatScreen: View {
    @ObservedObject var session: ChatSession
    @Binding var messageText: String
    @FocusState.Binding var isInputFocused: Bool
    let isOnline: Bool
    let wasResumed: Bool
    let showDebugStrip: Bool
    let showTimestamps: Bool
    @ObservedObject var diagnostics: DevDiagnostics
    let onSend: (String) -> Void
    let onLog: (String) -> Void
    let onPause: () -> Void
    let onEndConversation: () -> Void
    let onStartNewConversation: () -> Void

    @State private var sendingLabels: Set<UUID> = []
    @State private var trackedPending: Set<UUID> = []
    @State private var showResumeBanner: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if showDebugStrip {
                DebugStrip(diagnostics: diagnostics)
            }
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
                // Open WS counts as online even if NWPathMonitor briefly disagrees (VPN flicker).
                isOnline: isOnline || session.connection.isConnected,
                hasFailed: session.connection.isFailed,
                showTimestamps: showTimestamps,
                isInputFocused: $isInputFocused,
                onSend: onSend,
                onSuggestionTap: { text, id in
                    session.clearSuggestions(for: id)
                    onSend(text)
                },
                onRetry: { text, draftId in
                    if let draftId {
                        session.removeMessage(draftId: draftId)
                    }
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
