// Copyright PolyAI Limited

//  NewMessageNotifier.swift
//  Examples/SwiftUI/06-FullReference
//
//  Mirrors README:
//    - § "Side effects: client.events > In-app new-message alerts"
//
//  Fires a local notification banner with the *full* agent reply when a new
//  message arrives. Robustness:
//   • Reads the completed-message events (`.agentMessage` / `.liveAgentMessage`)
//     off `client.events` — the whole text + a stable, server-assigned
//     `messageId`, not the first streamed chunk.
//   • Dedupes on that `messageId` via a persisted (UserDefaults) store, so
//     resuming / reconnecting / relaunching never re-shows a message the user
//     was already notified about. (The SDK replays the conversation on resume,
//     which is exactly why an in-memory guard isn't enough.)
//
//  ⚠️ WORKAROUND — these are LOCAL notifications, NOT remote push.
//  PolyMessaging's realtime connection only delivers while the app is running, so
//  delivery degrades the further the app is from the foreground:
//   • Foreground            → banner fires immediately.
//   • Background grace (~30s)→ on backgrounding we hold a `beginBackgroundTask`
//                              so the socket survives briefly; a reply landing in
//                              that short window still banners.
//   • Suspended / locked /   → NOTHING arrives — iOS has torn the socket down,
//     force-quit               and no client-side trick can change that.
//
//  Real lock-screen delivery (even when the app is killed) needs APNs + a
//  server-side push integration — device-token registration plus a backend that
//  pushes on each new message. The SDK does not provide that yet — COMING SOON.
//  (A further client-only option, `BGAppRefreshTask`, can poll-and-notify when
//  iOS opportunistically wakes the app, but it's best-effort and iOS-timed, not
//  instant — not wired up here.)
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

/// Holds a `UIBackgroundTask` while the app is backgrounded so the realtime
/// socket survives the short grace period iOS grants (~30s) before suspending
/// the app. Lets a reply that lands just after backgrounding still banner.
@MainActor
final class BackgroundGraceKeeper {
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// True while we're inside the post-backgrounding grace window.
    var isActive: Bool { bgTask != .invalid }

    func begin() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "poly.newMessageGrace") { [weak self] in
            // iOS is reclaiming the time — always end the task or it force-quits us.
            self?.end()
        }
    }

    func end() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
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
    @State private var grace = BackgroundGraceKeeper()
    // SwiftUI-qualified because the SDK also exports an `Environment` type.
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

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
            // Keep the socket alive through the brief background grace window so a
            // reply landing right after backgrounding still banners.
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background: grace.begin()
                case .active:     grace.end()
                default:          break
                }
            }
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
            // Present while the app is active OR within the brief background grace
            // window (see BackgroundGraceKeeper). Read the live app state, not a
            // captured scenePhase, which would go stale inside this long loop. Once
            // iOS suspends the app neither is true and no events arrive anyway.
            let active = UIApplication.shared.applicationState == .active
            guard active || grace.isActive else { continue }

            present(id: message.id, title: message.title, body: message.body)
            store.markShown(message.id)
        }
    }

    private func present(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // `trigger: nil` delivers immediately (foreground or the grace window).
        // Never use a time-based trigger — it could fire long after the app is
        // suspended, which we don't want.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension View {
    /// Fire a local notification banner with the full agent reply for each new
    /// message while the app is in the foreground — plus the short background
    /// grace window. Dedupes (persisted) so resume / relaunch never re-notifies.
    /// See the file header: this is a workaround, not remote push (no lock-screen
    /// delivery when suspended/killed — that needs APNs, coming soon).
    func newMessageNotifications(for session: ChatSession) -> some View {
        modifier(NewMessageNotifierModifier(session: session))
    }
}
