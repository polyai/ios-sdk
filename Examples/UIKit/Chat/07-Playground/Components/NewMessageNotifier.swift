// Copyright PolyAI Limited

//  NewMessageNotifier.swift — Examples/UIKit/07-Playground
//
//  Local-notification banner with the full agent reply on each new message.
//  Foreground + a short (~30s) background grace window; once iOS suspends the app
//  nothing arrives — true lock-screen delivery needs APNs + backend push (not yet).
//  Dedupes on the server `messageId` (persisted) so replays on resume/relaunch
//  don't re-notify. Full walkthrough: README § "In-app new-message alerts".
//
//  Own one per chat surface; call `start(observing: session)` once the session
//  exists (e.g. in viewDidLoad). The default policy stays quiet while you're
//  looking at the chat (see `NotificationPolicy`).

import UIKit
import UserNotifications
import PolyMessaging

/// Controls *when* `NewMessageNotifier` raises a banner for a new agent message.
/// Pass it to `start(observing:policy:)` to suit your app.
enum NotificationPolicy {
    /// Only while the chat isn't on screen (default) — no banner while you're
    /// reading the conversation; it still fires in the background grace window.
    case whenBackgrounded

    /// On every new agent message, even while the chat is open in the foreground.
    case always

    /// Never post a banner.
    case never
}

/// Persisted, bounded set of already-notified `messageId`s — survives relaunch so
/// the SDK's replay-on-resume doesn't re-fire old banners.
struct NotifiedMessageStore {
    private static let key = "poly.notifiedMessageIds"
    private static let cap = 500

    private let defaults: UserDefaults
    private var ids: [String]      // insertion order, for trimming
    private var seen: Set<String>  // O(1) lookup

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
    private var bgTask: UIBackgroundTaskIdentifier = .invalid   // held while backgrounded (grace window)
    private var policy: NotificationPolicy = .whenBackgrounded

    // UITest hook: `-uiTestNotifyAlways` exercises the foreground banner even
    // though the default policy stays quiet while the chat is on screen.
    private var effectivePolicy: NotificationPolicy {
        CommandLine.arguments.contains("-uiTestNotifyAlways") ? .always : policy
    }

    func start(observing session: ChatSession, policy: NotificationPolicy = .whenBackgrounded) {
        self.policy = policy
        guard effectivePolicy != .never else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)

        // `events` is multicast, so observing it doesn't disturb the ChatSession UI.
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
            self?.endGraceWindow()   // iOS reclaiming the time — must end or it force-quits us
        }
    }

    private func endGraceWindow() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - Event handling

    private func handle(_ event: MessagingEvent) {
        // Completed messages only — full text + stable messageId (chunks ignored).
        let message: (id: String, title: String, body: String)?
        switch event {
        case .agentMessage(_, let p):     message = (p.messageId, p.agentName ?? "New message", p.text)
        case .liveAgentMessage(_, let p): message = (p.messageId, p.agentName ?? "New message", p.text)
        default:                          message = nil
        }
        guard let message else { return }

        guard !store.contains(message.id) else { return }   // skip replays
        // This notifier is owned by the on-screen chat, so foreground == viewing
        // this chat. `.whenBackgrounded` stays quiet then; `.always` always banners.
        let active = UIApplication.shared.applicationState == .active
        let wantBanner = effectivePolicy == .always || !active
        let canDeliver = active || bgTask != .invalid   // foreground, or the grace window
        if wantBanner && canDeliver {
            present(id: message.id, title: message.title, body: message.body)
        }
        // Mark every new message handled — so one suppressed on screen can't
        // re-notify when the SDK replays it on resume/relaunch.
        store.markShown(message.id)
    }

    private func present(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // trigger: nil = deliver now; never time-based (could fire after suspension).
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // `nonisolated`: the system may call this off the main actor; it touches no state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
