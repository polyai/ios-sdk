import SwiftUI
import PolyMessaging
#if canImport(UIKit)
import UIKit
#endif

struct SettingsSheet: View {
    @ObservedObject var settings: DevSettings
    @ObservedObject var diagnostics: DevDiagnostics
    let hasLiveSession: Bool
    let hasResumableSession: Bool
    let onApplyAndRestart: () -> Void
    var onForceReconnect: (() -> Void)? = nil
    var onSimulateDrop: (() -> Void)? = nil
    var onDisconnectClean: (() -> Void)? = nil
    var onSimulateServerReject: (() -> Void)? = nil
    var onSimulateIdleTimeout: (() -> Void)? = nil
    var onSendHeartbeat: (() -> Void)? = nil
    var onSendTypingStart: (() -> Void)? = nil
    var onSendTypingStop: (() -> Void)? = nil
    var onSendUserEndSession: (() -> Void)? = nil
    var onSendUserLeft: (() -> Void)? = nil
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    private var hasAnySession: Bool { hasLiveSession || hasResumableSession }

    var body: some View {
        NavigationView {
            Form {
                if hasAnySession {
                    Section {
                        sessionMismatchBanner
                    }
                }

                diagnosticsSection
                if hasLiveSession {
                    outgoingFramesSection
                    disconnectControlSection
                }
                displaySection
                environmentSection
                sessionSection
                advancedSection
                cursorSection
                resetSection
            }
            .navigationTitle("Dev Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    actionToast(toastMessage)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        }
        .navigationViewStyle(.stack)
    }

    private func actionToast(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private func fireAction(_ message: String, _ action: (() -> Void)?) {
        guard let action else { return }
        action()
        #if canImport(UIKit)
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
        #endif
        toastTask?.cancel()
        withAnimation { toastMessage = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - Banner

    private var sessionMismatchBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(hasLiveSession ? "Live session active" : "Resumable session exists").font(.subheadline.bold())
            }
            Text(hasLiveSession
                 ? "Streaming, identity, metadata, greeting and environment changes only apply to NEW sessions."
                 : "A previous session is stored on disk. Streaming and other session-creation settings here only apply once you start fresh — they don't change a resumed session.")
                .font(.caption).foregroundColor(.secondary)

            Button {
                onApplyAndRestart()
                dismiss()
            } label: {
                Label("Apply & Start New Session", systemImage: "arrow.clockwise.circle.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Diagnostics (read-only)

    private var diagnosticsSection: some View {
        Section(header: Text("Diagnostics"), footer: Text("Live values from the SDK. Counters reset when a fresh client is created.").font(.caption2)) {
            LabeledValue(label: "Status", value: diagnostics.connectionLabel)
            LabeledValue(label: "Session ID", value: shortened(diagnostics.sessionId))
            LabeledValue(label: "Ready", value: diagnostics.isReady ? "yes" : "no")
            LabeledValue(label: "Last sequence", value: "\(diagnostics.lastSequence)")
            LabeledValue(label: "Frames in / out", value: "\(diagnostics.framesIn) / \(diagnostics.framesOut)")
            LabeledValue(label: "Chunks received", value: "\(diagnostics.chunksIn)")
            LabeledValue(label: "Heartbeats in", value: "\(diagnostics.heartbeatsIn)")
            LabeledValue(label: "Reconnects", value: "\(diagnostics.reconnectCount)")
            LabeledValue(label: "Last frame", value: lastFrameLabel())
            if let s = diagnostics.streamingCapability {
                LabeledValue(label: "Server streaming", value: s ? "yes" : "no")
            }
            if let m = diagnostics.maxMessageSize {
                LabeledValue(label: "Max message size", value: m == 0 ? "unlimited" : "\(m) bytes")
            }
            if let h = diagnostics.serverHeartbeatSeconds {
                LabeledValue(label: "Server heartbeat", value: h == 0 ? "disabled" : "\(h)s")
            }
            if let r = diagnostics.serverMaxReconnectAttempts {
                LabeledValue(label: "Server max reconnect", value: r == 0 ? "unlimited" : "\(r)")
            }
        }
    }

    // MARK: - Live Actions

    private var outgoingFramesSection: some View {
        Section(header: Text("Send frames"), footer: Text("Wire-level events sent directly to the server via the raw connection.").font(.caption2)) {
            actionRow("Send HEARTBEAT", systemImage: "waveform.path.ecg") {
                fireAction("Heartbeat sent", onSendHeartbeat)
            }
            actionRow("Send USER_TYPING (started)", systemImage: "ellipsis.bubble") {
                fireAction("Typing started", onSendTypingStart)
            }
            actionRow("Send USER_TYPING (stopped)", systemImage: "ellipsis.bubble.fill") {
                fireAction("Typing stopped", onSendTypingStop)
            }
            actionRow("Send USER_END_SESSION", systemImage: "xmark.circle", isDestructive: true) {
                fireAction("End session sent", onSendUserEndSession)
            }
            actionRow("Send USER_LEFT", systemImage: "rectangle.portrait.and.arrow.right", isDestructive: true) {
                fireAction("User left sent", onSendUserLeft)
            }
        }
    }

    private var disconnectControlSection: some View {
        Section(header: Text("Disconnect / reconnect"), footer: Text("Exercises each ConnectionService close-code path. 1006 reconnects, 4001 refetches, 1000 is terminal.").font(.caption2)) {
            actionRow("Force reconnect (1006)", systemImage: "arrow.clockwise") {
                fireAction("Reconnect triggered", onForceReconnect)
            }
            actionRow("Simulate network drop (1006)", systemImage: "wifi.slash") {
                fireAction("Simulated network drop", onSimulateDrop)
            }
            actionRow("Simulate idle timeout (4002)", systemImage: "clock.badge.exclamationmark") {
                fireAction("Idle-timeout close sent", onSimulateIdleTimeout)
            }
            actionRow("Simulate server reject (4001)", systemImage: "exclamationmark.shield", isDestructive: true) {
                fireAction("Server-reject close sent", onSimulateServerReject)
            }
            actionRow("Clean disconnect (1000)", systemImage: "xmark.octagon.fill", isDestructive: true) {
                fireAction("Clean disconnect sent", onDisconnectClean)
            }
        }
    }

    private func actionRow(_ title: String, systemImage: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundColor(isDestructive ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .disabled(!hasLiveSession)
    }

    private func lastFrameLabel() -> String {
        guard let at = diagnostics.lastInboundAt else { return "—" }
        let s = Int(Date().timeIntervalSince(at))
        if s < 1 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        return "\(s / 60)m ago"
    }

    private func shortened(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        if s.count <= 12 { return s }
        return s.prefix(4) + "…" + s.suffix(8)
    }

    // MARK: - Display toggles

    private var displaySection: some View {
        Section(header: Text("Display"), footer: Text("Visual debug aids inside the chat screen.").font(.caption2)) {
            Toggle("Show debug strip in chat", isOn: Binding(
                get: { settings.showDebugStrip },
                set: { settings.showDebugStrip = $0 }
            ))
            Toggle("Progressive streaming bubble", isOn: Binding(
                get: { settings.progressiveStreaming },
                set: { settings.progressiveStreaming = $0 }
            ))
            Toggle("Message timestamps", isOn: Binding(
                get: { settings.showMessageTimestamps },
                set: { settings.showMessageTimestamps = $0 }
            ))
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section(header: Text("Environment"), footer: Text("Switches the REST + WebSocket base URLs. Applies on next session creation.").font(.caption2)) {
            Picker("Target", selection: Binding(
                get: { settings.environmentKind },
                set: { settings.environmentKind = $0 }
            )) {
                ForEach(DevSettings.EnvironmentKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            switch settings.environmentKind {
            case .cluster:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cluster name").font(.caption).foregroundColor(.secondary)
                    TextField("us-1", text: Binding(
                        get: { settings.clusterName },
                        set: { settings.clusterName = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    Text("Resolves to messaging.<name>.poly.ai").font(.caption2).foregroundColor(.secondary)
                }
            case .custom:
                VStack(alignment: .leading, spacing: 4) {
                    Text("REST base URL").font(.caption).foregroundColor(.secondary)
                    TextField("https://...", text: Binding(
                        get: { settings.customRestURL },
                        set: { settings.customRestURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)

                    Text("WS base URL").font(.caption).foregroundColor(.secondary)
                    TextField("wss://.../ws", text: Binding(
                        get: { settings.customWsURL },
                        set: { settings.customWsURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                }
            default:
                EmptyView()
            }

            HStack {
                Text("Resolved")
                Spacer()
                Text(settings.environmentDisplayName()).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
        }
    }

    // MARK: - Session creation params

    private var sessionSection: some View {
        Section(header: Text("Session"), footer: Text("Sent in the /sessions request body.").font(.caption2)) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Streaming enabled", isOn: Binding(
                    get: { settings.streamingEnabled },
                    set: { settings.streamingEnabled = $0 }
                ))
                if hasAnySession && settings.streamingEnabled != settings.lastAppliedStreamingEnabled {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                        Text("Won't apply to current session — start fresh to take effect.")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Greeting message").font(.caption).foregroundColor(.secondary)
                TextField("(server default)", text: Binding(
                    get: { settings.greetingMessage },
                    set: { settings.greetingMessage = $0 }
                ))
                .textInputAutocapitalization(.sentences)
            }

            Picker("Log level", selection: Binding(
                get: { settings.logLevel },
                set: { settings.logLevel = $0 }
            )) {
                Text("None").tag(LogLevel.none)
                Text("Error").tag(LogLevel.error)
                Text("Warn").tag(LogLevel.warn)
                Text("Info").tag(LogLevel.info)
                Text("Debug").tag(LogLevel.debug)
            }
        }
    }

    // MARK: - Advanced timing

    private var advancedSection: some View {
        Section(header: Text("Advanced"), footer: Text("0 = use SDK default. Server SessionCapabilities still wins after SESSION_START.").font(.caption2)) {
            Stepper(value: Binding(
                get: { settings.heartbeatIntervalSeconds },
                set: { settings.heartbeatIntervalSeconds = $0 }
            ), in: 0...300, step: 5) {
                LabeledValue(label: "Heartbeat", value: secondsLabel(settings.heartbeatIntervalSeconds, defaultLabel: "30s"))
            }

            Stepper(value: Binding(
                get: { settings.sessionTimeoutSeconds },
                set: { settings.sessionTimeoutSeconds = $0 }
            ), in: 0...86400, step: 60) {
                LabeledValue(label: "Session timeout", value: secondsLabel(settings.sessionTimeoutSeconds, defaultLabel: "1h"))
            }

            Stepper(value: Binding(
                get: { settings.maxReconnectAttempts },
                set: { settings.maxReconnectAttempts = $0 }
            ), in: 0...50, step: 1) {
                LabeledValue(label: "Max reconnects", value: settings.maxReconnectAttempts == 0 ? "10" : "\(settings.maxReconnectAttempts)")
            }
        }
    }

    // MARK: - Cursor (debug only — read-only for now)

    private var cursorSection: some View {
        Section(header: Text("Reconnect Cursor"), footer: Text("Debug only. Overriding the cursor requires an SDK debug hook that isn't exposed yet — ask the SDK author to add a public `setCursorOverride(_:)` if you need to test replay from an arbitrary sequence.").font(.caption2)) {
            HStack {
                Text("Override").foregroundColor(.secondary)
                Spacer()
                Text("Not supported").foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                settings.resetToDefaults()
            } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
            }
        }
    }

    // MARK: - Helpers

    private func secondsLabel(_ secs: Int, defaultLabel: String) -> String {
        if secs == 0 { return defaultLabel + " (default)" }
        if secs >= 3600 { return "\(secs / 3600)h" + (secs % 3600 == 0 ? "" : " \(secs % 3600 / 60)m") }
        if secs >= 60 { return "\(secs / 60)m" + (secs % 60 == 0 ? "" : " \(secs % 60)s") }
        return "\(secs)s"
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

private struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
