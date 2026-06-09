// Copyright PolyAI Limited

//  NewMessageNotifier.swift — Examples/SwiftUI/03-RichContent
//
//  Local-notification banner with the full agent reply on each new message.
//  Foreground + a short (~30s) background grace window; once iOS suspends the app
//  nothing arrives — true lock-screen delivery needs APNs + backend push (not yet).
//  Dedupes on the server `messageId` (persisted) so replays on resume/relaunch
//  don't re-notify. Full walkthrough: README § "In-app new-message alerts".
//
//  Attach with `.newMessageNotifications(for: session)` — the default policy stays
//  quiet while you're looking at the chat (see `NotificationPolicy`).

import SwiftUI
import UIKit
import UserNotifications
import PolyMessaging

/// Controls *when* `newMessageNotifications` raises a banner for a new agent
/// message. Flip it at the call site to suit your app.
enum NotificationPolicy {
    /// Only while the chat isn't on screen (default) — no banner while you're
    /// reading the conversation; it still fires in the background grace window.
    case whenBackgrounded

    /// On every new agent message, even while the chat is open in the foreground.
    case always

    /// Never post a banner.
    case never
}

/// Opts the foreground app into banners — iOS suppresses them for the active app otherwise.
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

/// Holds a `UIBackgroundTask` while backgrounded so the socket survives the ~30s
/// grace window before iOS suspends the app.
@MainActor
final class BackgroundGraceKeeper {
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var isActive: Bool { bgTask != .invalid }

    func begin() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "poly.newMessageGrace") { [weak self] in
            self?.end()   // iOS reclaiming the time — must end or it force-quits us
        }
    }

    func end() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
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
private struct NewMessageNotifierModifier: ViewModifier {
    let session: ChatSession
    let policy: NotificationPolicy
    @State private var store = NotifiedMessageStore()
    @State private var grace = BackgroundGraceKeeper()
    // SwiftUI-qualified: the SDK also exports an `Environment` type.
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    // UITest hook: `-uiTestNotifyAlways` exercises the foreground banner even
    // though the default policy stays quiet while the chat is on screen.
    private var effectivePolicy: NotificationPolicy {
        CommandLine.arguments.contains("-uiTestNotifyAlways") ? .always : policy
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard effectivePolicy != .never else { return }
                let center = UNUserNotificationCenter.current()
                center.delegate = ForegroundBannerPresenter.shared
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            .task { await observe() }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background: grace.begin()
                case .active:     grace.end()
                default:          break
                }
            }
    }

    // `events` is multicast, so observing it doesn't disturb the ChatSession UI.
    private func observe() async {
        guard effectivePolicy != .never else { return }
        for await event in session.client.events {
            // Completed messages only — full text + stable messageId (chunks ignored).
            let message: (id: String, title: String, body: String)?
            switch event {
            case .agentMessage(_, let p):     message = (p.messageId, p.agentName ?? "New message", p.text)
            case .liveAgentMessage(_, let p): message = (p.messageId, p.agentName ?? "New message", p.text)
            default:                          message = nil
            }
            guard let message else { continue }

            guard !store.contains(message.id) else { continue }   // skip replays
            // The modifier lives on the chat surface, so foreground == viewing this
            // chat. `.whenBackgrounded` stays quiet then; `.always` always banners.
            // Read live app state, not the captured scenePhase (stale in this loop).
            let active = UIApplication.shared.applicationState == .active
            let wantBanner = effectivePolicy == .always || !active
            let canDeliver = active || grace.isActive   // foreground, or the grace window
            if wantBanner && canDeliver {
                present(id: message.id, title: message.title, body: message.body)
            }
            // Mark every new message handled — so one suppressed on screen can't
            // re-notify when the SDK replays it on resume/relaunch.
            store.markShown(message.id)
        }
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
}

extension View {
    /// Banner the full agent reply for each new message; persisted dedupe so
    /// resume/relaunch never re-notifies. A workaround, not remote push — see the
    /// file header. `policy` decides when it fires — default `.whenBackgrounded`
    /// stays quiet while the chat is on screen.
    func newMessageNotifications(
        for session: ChatSession,
        policy: NotificationPolicy = .whenBackgrounded
    ) -> some View {
        modifier(NewMessageNotifierModifier(session: session, policy: policy))
    }
}
