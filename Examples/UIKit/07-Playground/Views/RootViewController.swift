// Copyright PolyAI Limited

//  RootViewController.swift
//  Examples/UIKit/07-Playground
//
//  Playground container — the UIKit equivalent of the SwiftUI 07 ContentView.
//  Owns the ChatSession plus the dev surfaces: DevSettings (runtime config),
//  DevDiagnostics (live counters), a filtered event log, the Dev Settings /
//  Logs sheets, and raw-transport protocol actions via `getConnection()`.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

final class RootViewController: UIViewController {

    private enum Screen { case connect, loading, chat, error }

    private let devSettings = DevSettings()
    private let diagnostics = DevDiagnostics()
    private var logs: [LogEntry] = []

    private var session: ChatSession?
    private var wasResumed = false
    private var screen: Screen = .connect
    private var current: UIViewController?
    private var lifecycleTasks: [Task<Void, Never>] = []
    private var observedFirstSessionId: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "PolyMessaging"
        navigationItem.backButtonDisplayMode = .minimal
        showConnect()
    }

    deinit { lifecycleTasks.forEach { $0.cancel() } }

    // MARK: - Screen transitions

    private func transition(to child: UIViewController) {
        if let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        child.didMove(toParent: self)
        current = child
        updateNavItems()
    }

    private func updateNavItems() {
        if screen == .connect {
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "gearshape"),
                primaryAction: UIAction { [weak self] _ in self?.presentSettings() }
            )
            navigationItem.rightBarButtonItem?.accessibilityLabel = "Dev Settings"
            return
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            primaryAction: UIAction { [weak self] _ in self?.showConnect() }
        )
        let menu = UIMenu(children: [
            UIAction(title: "View Logs", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in self?.presentLogs() },
            UIAction(title: "Dev Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.presentSettings() },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "End Conversation", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in self?.confirmEnd() },
            ]),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
    }

    private func showConnect() {
        screen = .connect
        let vc = ConnectViewController(
            hasActiveSession: session != nil,
            canResume: PolyMessaging.hasResumableSession(),
            environmentLabel: devSettings.environmentDisplayName(),
            hasCustomSettings: devSettings.hasCustomization,
            onResume: { [weak self] in self?.configureAndStart(forceFresh: false) },
            onStartNew: { [weak self] in self?.configureAndStart(forceFresh: true) }
        )
        transition(to: vc)
    }

    private func showLoading() {
        screen = .loading
        transition(to: LoadingViewController())
    }

    private func showChat() {
        guard let session, screen != .chat else { return }
        screen = .chat
        transition(to: ChatViewController(
            session: session,
            wasResumed: wasResumed,
            showDebugStrip: devSettings.showDebugStrip,
            showTimestamps: devSettings.showMessageTimestamps,
            diagnostics: diagnostics
        ))
    }

    private func showError(_ message: String) {
        screen = .error
        transition(to: ErrorViewController(message: message, onBack: { [weak self] in self?.showConnect() }))
    }

    // MARK: - Sheets

    private func presentLogs() {
        let vc = LogsViewController(logs: logs)
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    private func presentSettings() {
        let vc = SettingsViewController(
            settings: devSettings,
            diagnostics: diagnostics,
            hasLiveSession: session != nil,
            hasResumableSession: PolyMessaging.hasResumableSession()
        )
        vc.onApplyAndRestart = { [weak self] in self?.applySettingsAndRestart() }
        vc.onForceReconnect = { [weak self] in self?.closeWith(code: 1006, reason: "Debug force reconnect") }
        vc.onSimulateDrop = { [weak self] in self?.closeWith(code: 1006, reason: "Debug simulated drop") }
        vc.onDisconnectClean = { [weak self] in self?.closeWith(code: 1000, reason: "Debug clean disconnect") }
        vc.onSimulateServerReject = { [weak self] in self?.closeWith(code: 4001, reason: "Debug server-reject simulation") }
        vc.onSimulateIdleTimeout = { [weak self] in self?.closeWith(code: 4002, reason: "Debug idle-timeout simulation") }
        vc.onSendHeartbeat = { [weak self] in self?.rawSend(.heartbeat) }
        vc.onSendTypingStart = { [weak self] in self?.rawSend(.userTyping(.started)) }
        vc.onSendTypingStop = { [weak self] in self?.rawSend(.userTyping(.stopped)) }
        vc.onSendUserEndSession = { [weak self] in self?.rawSend(.userEndConversation) }
        vc.onSendUserLeft = { [weak self] in self?.rawSend(.userLeft) }
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    // MARK: - Nav actions

    private func confirmEnd() {
        let alert = UIAlertController(
            title: "End Conversation",
            message: "This will permanently end the current conversation. You won't be able to resume it.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "End Conversation", style: .destructive) { [weak self] _ in
            self?.endConversation()
        })
        present(alert, animated: true)
    }

    private func endConversation() {
        let pending = session
        Task { @MainActor [weak self] in
            try? await pending?.end()
            self?.session = nil
            self?.wasResumed = false
            self?.logs.removeAll()
            self?.diagnostics.reset()
            self?.showConnect()
        }
    }

    // MARK: - SDK lifecycle

    private func configureAndStart(forceFresh: Bool) {
        if let existing = session {
            if forceFresh {
                wasResumed = false
                session = ChatSession(client: existing.client)
                logs.removeAll()
                log("Ending current session and starting fresh...")
                showLoading()
                Task { @MainActor [weak self] in
                    do { try await existing.client.startNewSession() }
                    catch {
                        self?.log("Start new failed: \(error)")
                        // The SDK throws PolyError, which isn't LocalizedError —
                        // use String(describing:) for the actual case text.
                        self?.showError("Couldn't start a new session.\n\(String(describing: error))")
                    }
                }
            } else {
                showChat()
            }
            return
        }

        // Streaming behaviour is driven by `Configuration.streamingEnabled`
        // (set in the Settings sheet). No per-session override needed here.
        let config = devSettings.buildConfiguration()
        let s = forceFresh
            ? PolyMessaging.start(config)
            : PolyMessaging.chat(config)
        diagnostics.attach(to: s.client)
        session = s
        wasResumed = false
        observedFirstSessionId = nil
        showLoading()
        log(forceFresh ? "Starting new session..." : "Resuming session...")
        subscribeLifecycle(to: s.client)
    }

    private func subscribeLifecycle(to client: PolyMessagingClient) {
        lifecycleTasks.forEach { $0.cancel() }
        lifecycleTasks = []

        lifecycleTasks.append(Task { @MainActor [weak self] in
            for await event in client.events {
                guard let self else { return }
                if self.shouldLog(event) { self.logs.append(EventLogger.makeEntry(event: event)) }
                if case .sessionStart = event, self.screen == .loading { self.showChat() }
                if case .disconnected(let err) = event, let err, self.screen == .loading {
                    self.showError("Couldn't connect.\n\(err)")
                }
            }
        })

        lifecycleTasks.append(Task { @MainActor [weak self] in
            for await status in client.connectionStatus {
                guard let self else { return }
                self.log("Connection: \(status)")
                if case .failed(let reason) = status, self.screen == .loading {
                    let message = reason.map { String(describing: $0) } ?? "Unknown failure"
                    self.showError("Connection failed.\n\(message)")
                }
            }
        })

        lifecycleTasks.append(Task { @MainActor [weak self] in
            for await state in client.sessionState {
                guard let self else { return }
                if state.status == .restored {
                    self.wasResumed = true
                    self.log("Resumed previous conversation")
                }
                if state.isReady, self.screen == .loading || self.screen == .error { self.showChat() }
                if state.isReady, let sid = state.sessionId, self.observedFirstSessionId == nil, !self.wasResumed {
                    self.observedFirstSessionId = sid
                    self.devSettings.recordSessionApplied()
                }
                if state.isError, self.screen == .loading {
                    self.showError(state.errorMessage ?? "Couldn't start the session.")
                }
            }
        })
    }

    private func applySettingsAndRestart() {
        let pending = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await pending?.end()
            await pending?.client.shutdown()
            self.session = nil
            self.wasResumed = false
            self.logs.removeAll()
            self.diagnostics.reset()
            self.devSettings.recordSessionApplied()
            self.configureAndStart(forceFresh: true)
        }
    }

    // MARK: - Raw transport (getConnection escape hatch)

    private func rawSend(_ event: OutgoingEvent) {
        guard let client = session?.client else { return }
        log("Debug send: \(event)")
        Task { @MainActor in
            await client.getConnection().send(event)
            diagnostics.recordOutgoing()
        }
    }

    private func closeWith(code: Int, reason: String) {
        guard let client = session?.client else { return }
        log("Debug: close with code \(code) — \(reason)")
        Task { await client.getConnection().disconnect(code: code, reason: reason) }
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
