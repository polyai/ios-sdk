// Copyright PolyAI Limited

//  NewMessageNotifier.swift
//  Examples/SwiftUI/07-Playground
//
//  Mirrors README:
//    - § "Side effects: client.events > In-app new-message alerts (foreground only)"
//
//  Fires a local notification banner with the *full* agent reply when a new
//  message arrives while the app is in the foreground.
//
//  Two things make this robust:
//   • It reads the completed-message events (`.agentMessage` / `.liveAgentMessage`)
//     off `client.events`, which carry the whole text — not the first streamed
//     chunk — and a stable, server-assigned `messageId`.
//   • It dedupes on that `messageId` using a small UserDefaults-backed store, so
//     resuming a conversation or relaunching the app never re-shows a message the
//     user was already notified about. (The SDK replays the conversation on
//     resume, which is exactly why an in-memory guard isn't enough.)
//
//  There is deliberately no background path: PolyMessaging's realtime connection
//  only delivers while the app is running. Real background delivery would need
//  APNs + a server-side push integration, which the SDK doesn't provide.
//
//  Attach with `.newMessageNotifications(for: session)` (see the View extension
//  at the bottom).

import SwiftUI
import UIKit
import UserNotifications
import PolyMessaging

/// `UNUserNotificationCenter` hides banners for the foreground app unless a
/// delegate opts in via `willPresent` — that's what makes the alert show up
/// while the user is in the app.
private final class ForegroundBannerPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundBannerPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Remembers which agent `messageId`s we've already notified for, persisted so
/// the guard survives an app relaunch. Bounded so it can't grow without limit.
struct NotifiedMessageStore {
    private static let key = "poly.notifiedMessageIds"
    private static let cap = 500

    private let defaults: UserDefaults
    private var ids: [String]      // insertion-ordered, for trimming
    private var seen: Set<String>  // mirror, for O(1) lookups

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = defaults.stringArray(forKey: Self.key) ?? []
        self.seen = Set(ids)
    }

    func contains(_ id: String) -> Bool { seen.contains(id) }

    mutating func markShown(_ id: String) {
        guard seen.insert(id).inserted else { return }
        ids.append(id)
        if ids.count > Self.cap {
            let overflow = ids.count - Self.cap
            ids.prefix(overflow).forEach { seen.remove($0) }
            ids.removeFirst(overflow)
        }
        defaults.set(ids, forKey: Self.key)
    }
}

@MainActor
private struct NewMessageNotifierModifier: ViewModifier {
    let session: ChatSession
    @State private var store = NotifiedMessageStore()

    func body(content: Content) -> some View {
        content
            .onAppear {
                let center = UNUserNotificationCenter.current()
                center.delegate = ForegroundBannerPresenter.shared
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            // Consume the *completed* message events — full text + a stable
            // server messageId. (Partial chunks arrive via .agentMessageChunk and
            // are ignored.) `events` is multicast, so this doesn't disturb the
            // ChatSession driving the UI.
            .task { await observe() }
    }

    private func observe() async {
        for await event in session.client.events {
            let message: (id: String, title: String, body: String)?
            switch event {
            case .agentMessage(_, let p):
                message = (p.messageId, p.agentName ?? "New message", p.text)
            case .liveAgentMessage(_, let p):
                message = (p.messageId, p.agentName ?? "New message", p.text)
            default:
                message = nil
            }
            guard let message else { continue }

            // Already shown — covers resume / reconnect / relaunch replays.
            guard !store.contains(message.id) else { continue }
            // Foreground-only. Read the live app state (not a captured scenePhase,
            // which would go stale inside this long-running loop). Don't mark when
            // inactive: a genuinely-missed message can then show on the next
            // foreground replay.
            guard UIApplication.shared.applicationState == .active else { continue }

            present(id: message.id, title: message.title, body: message.body)
            store.markShown(message.id)
        }
    }

    private func present(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // `trigger: nil` delivers immediately. Never use a time-based trigger —
        // that could fire after the app is backgrounded, which we don't want.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension View {
    /// Fire a local notification banner with the full agent reply for each new
    /// message while the app is in the foreground. Dedupes (persisted) so resume
    /// / relaunch never re-notifies. See the file header for why there's no
    /// background path.
    func newMessageNotifications(for session: ChatSession) -> some View {
        modifier(NewMessageNotifierModifier(session: session))
    }
}
