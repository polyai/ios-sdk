// Copyright PolyAI Limited

//  NewMessageNotifier.swift
//  Examples/UIKit/06-FullReference
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
//     was already notified about.
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
//  Own one per chat surface, then call `start(observing: session)` once the
//  ChatSession exists (e.g. in viewDidLoad).

import UIKit
import UserNotifications
import PolyMessaging

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
final class NewMessageNotifier: NSObject, UNUserNotificationCenterDelegate {

    private var task: Task<Void, Never>?
    private var store = NotifiedMessageStore()
    // Held while backgrounded so the realtime socket survives the ~30s grace
    // window iOS grants before suspending the app.
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func start(observing session: ChatSession) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Hold a background task across the grace window so a reply landing just
        // after backgrounding still banners.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)

        // Consume the *completed* message events — full text + a stable server
        // messageId. (Partial chunks arrive via .agentMessageChunk and are
        // ignored.) `events` is multicast, so this doesn't disturb the
        // ChatSession driving the UI.
        task?.cancel()
        task = Task { [weak self] in
            for await event in session.client.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        NotificationCenter.default.removeObserver(self)
        endGraceWindow()
    }

    // MARK: - Background grace window

    @objc private func appDidBackground() { beginGraceWindow() }
    @objc private func appWillForeground() { endGraceWindow() }

    private func beginGraceWindow() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "poly.newMessageGrace") { [weak self] in
            // iOS is reclaiming the time — always end the task or it force-quits us.
            self?.endGraceWindow()
        }
    }

    private func endGraceWindow() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - Event handling

    private func handle(_ event: MessagingEvent) {
        let message: (id: String, title: String, body: String)?
        switch event {
        case .agentMessage(_, let p):
            message = (p.messageId, p.agentName ?? "New message", p.text)
        case .liveAgentMessage(_, let p):
            message = (p.messageId, p.agentName ?? "New message", p.text)
        default:
            message = nil
        }
        guard let message else { return }

        // Already shown — covers resume / reconnect / relaunch replays.
        guard !store.contains(message.id) else { return }
        // Present while the app is active OR within the brief background grace
        // window. Once iOS suspends the app neither is true and no events arrive.
        let active = UIApplication.shared.applicationState == .active
        guard active || bgTask != .invalid else { return }

        present(id: message.id, title: message.title, body: message.body)
        store.markShown(message.id)
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

    // Present as a banner even while the app is foreground — UNUserNotification-
    // Center otherwise suppresses banners for the active app. `nonisolated`: the
    // system may invoke this off the main actor, and it touches no state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
