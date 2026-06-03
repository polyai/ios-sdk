// Copyright PolyAI Limited

//  NewMessageNotifier.swift — Examples/SwiftUI/06-FullReference
//
//  Local-notification banner with the full agent reply on each new message.
//  Foreground + a short (~30s) background grace window; once iOS suspends the app
//  nothing arrives — true lock-screen delivery needs APNs + backend push (not yet).
//  Dedupes on the server `messageId` (persisted) so replays on resume/relaunch
//  don't re-notify. Full walkthrough: README § "In-app new-message alerts".
//
//  Attach with `.newMessageNotifications(for: session)`.

import SwiftUI
import UIKit
import UserNotifications
import PolyMessaging

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
    @State private var store = NotifiedMessageStore()
    @State private var grace = BackgroundGraceKeeper()
    // SwiftUI-qualified: the SDK also exports an `Environment` type.
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
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
            // Foreground or grace window only. Read live app state, not the captured
            // scenePhase (which goes stale in this long-running loop).
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
        // trigger: nil = deliver now; never time-based (could fire after suspension).
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension View {
    /// Banner the full agent reply for each new message (foreground + grace window);
    /// persisted dedupe so resume/relaunch never re-notifies. A workaround, not
    /// remote push — see the file header.
    func newMessageNotifications(for session: ChatSession) -> some View {
        modifier(NewMessageNotifierModifier(session: session))
    }
}
