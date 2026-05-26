//  RootViewController.swift
//  Examples/UIKit/06-FullReference
//
//  Container that owns the single ChatSession and swaps between the connect /
//  loading / chat / error child view controllers — the UIKit equivalent of the
//  SwiftUI 06 `ContentView` screen state machine. The back chevron pauses back
//  to connect WITHOUT ending the session; the xmark ends it for good.
//
//  Lifecycle transitions (loading -> chat / error) are driven off the client's
//  event / connectionStatus / sessionState streams, mirroring ContentView.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

final class RootViewController: UIViewController {

    private enum Screen { case connect, loading, chat, error }

    private var session: ChatSession?
    private var wasResumed = false
    private var screen: Screen = .connect
    private var current: UIViewController?

    /// Tied to the current client (not the ChatSession) so it keeps working
    /// across an in-place start-new on the same client. Cancelled and re-armed
    /// only when a brand-new client is created.
    private var lifecycleTasks: [Task<Void, Never>] = []

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
        guard screen != .connect else {
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = nil
            return
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            primaryAction: UIAction { [weak self] _ in self?.showConnect() }
        )
        let end = UIBarButtonItem(
            image: UIImage(systemName: "xmark.circle"),
            primaryAction: UIAction { [weak self] _ in self?.confirmEnd() }
        )
        end.accessibilityLabel = "End Conversation"
        navigationItem.rightBarButtonItem = end
    }

    private func showConnect() {
        screen = .connect
        let vc = ConnectViewController(
            hasActiveSession: session != nil,
            canResume: PolyMessaging.hasResumableSession(),
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
        transition(to: ChatViewController(session: session, wasResumed: wasResumed))
    }

    private func showError(_ message: String) {
        screen = .error
        transition(to: ErrorViewController(message: message, onBack: { [weak self] in self?.showConnect() }))
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
            self?.showConnect()
        }
    }

    // MARK: - SDK lifecycle

    private func configureAndStart(forceFresh: Bool) {
        if let existing = session {
            if forceFresh {
                // Reuse the live client; spin up a fresh ChatSession and ask
                // the server for a brand-new conversation. The persistent
                // lifecycle subscriptions (same client) flip us back to chat.
                wasResumed = false
                session = ChatSession(client: existing.client)
                showLoading()
                Task { @MainActor [weak self] in
                    do { try await existing.client.startNewSession() }
                    // The SDK throws PolyError, which isn't LocalizedError —
                    // use String(describing:) for the actual case text.
                    catch { self?.showError("Couldn't start a new session.\n\(String(describing: error))") }
                }
            } else {
                showChat()
            }
            return
        }

        // The connection config was set once in AppDelegate via initialize(...);
        // the no-arg facade reuses it. Resume vs start-fresh is the only
        // difference here.
        let s = forceFresh ? PolyMessaging.start() : PolyMessaging.chat()
        session = s
        wasResumed = false
        showLoading()
        subscribeLifecycle(to: s.client)
    }

    private func subscribeLifecycle(to client: PolyMessagingClient) {
        lifecycleTasks.forEach { $0.cancel() }
        lifecycleTasks = []

        lifecycleTasks.append(Task { @MainActor [weak self] in
            for await event in client.events {
                guard let self else { return }
                if case .sessionStart = event, self.screen == .loading { self.showChat() }
                if case .disconnected(let err) = event, let err, self.screen == .loading {
                    self.showError("Couldn't connect.\n\(err)")
                }
            }
        })

        lifecycleTasks.append(Task { @MainActor [weak self] in
            for await status in client.connectionStatus {
                guard let self else { return }
                if case .failed(let reason) = status, self.screen == .loading {
                    let message = reason.map { String(describing: $0) } ?? "Unknown failure"
                    self.showError("Connection failed.\n\(message)")
                }
            }
        })

        lifecycleTasks.append(Task { @MainActor [weak self] in
            for await state in client.sessionState {
                guard let self else { return }
                if state.status == .restored { self.wasResumed = true }
                if state.isReady, self.screen == .loading || self.screen == .error { self.showChat() }
                if state.isError, self.screen == .loading {
                    self.showError(state.errorMessage ?? "Couldn't start the session.")
                }
            }
        })
    }
}
