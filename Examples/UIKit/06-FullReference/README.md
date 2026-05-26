# 06-FullReference (UIKit)

The complete UIKit reference app on top of [`05-Handoff`](../05-Handoff/) — every feature from 02–05 folded into one production-shaped flow (`connect → loading → chat → error`), plus the lifecycle plumbing the lighter levels skip: resume-or-start, in-place start-new, recoverable error routing, delayed "Sending…" labels, and child-view-controller containment driven entirely by SDK streams.

- **Interface:** programmatic (no storyboard). `SceneDelegate` wraps a `RootViewController` in a `UINavigationController`.
- **Lifecycle:** `AppDelegate` (`@main`) + `SceneDelegate`.

## Run it

```bash
open FullReferenceUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your connector token in `AppDelegate.swift` (currently `"YOUR_CONNECTOR_TOKEN"`).

## What this example demonstrates

- A screen-state machine (`enum Screen { case connect, loading, chat, error }`) driving child-VC containment
- Resume-or-start picker driven by `PolyMessaging.hasResumableSession()` + `chat()` vs `start()`
- Loading → chat / error transitions driven by `client.events`, `client.connectionStatus`, and `client.sessionState` — tied to the **client**, not the session, so they survive in-place start-new
- A recoverable error screen with a "Go Back" route to connect (not a latched terminal flag)
- Nav-bar split: chevron pauses to connect *without ending*; xmark ends with a confirm alert
- In-place start-new via `session.clearChat()` + `session.client.startNewSession()` — no screen change
- Destructive `session.end()` followed by a return to connect
- Delayed "Sending…" label (~500ms debounce) so fast confirmations never flash it
- Retry that calls `session.removeMessage(draftId:)` before re-sending, so failed bubbles never linger

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them as one concrete multi-screen app.

## How it works

Each subsection leads with **the SDK call** (one or a few lines — the actual API), then shows **how it's wired into a view controller**.

### Screen-state machine + child-VC containment — `Views/RootViewController.swift`

The root owns the single `ChatSession` and a `Screen` enum, swapping one child view controller in at a time. Connect / loading / chat / error never each talk to the SDK directly — only the root does — so the session survives every screen transition.

The SDK calls:

```swift
PolyMessaging.initialize(_:)        // once, in AppDelegate — connection details
PolyMessaging.hasResumableSession() // side-effect-free probe of the on-disk session store
PolyMessaging.chat()                // resume the persisted session if valid, else start fresh
PolyMessaging.start()               // always discard any stored session and start fresh
```

In a view controller:

```swift
final class RootViewController: UIViewController {
    private enum Screen { case connect, loading, chat, error }

    private var session: ChatSession?
    private var wasResumed = false
    private var screen: Screen = .connect
    private var current: UIViewController?

    /// Tied to the current client (not the ChatSession) so it keeps working
    /// across in-place start-new on the same client. Re-armed only when a
    /// brand-new client is created.
    private var lifecycleTasks: [Task<Void, Never>] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        showConnect()
    }

    deinit { lifecycleTasks.forEach { $0.cancel() } }

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
}
```

**Under the hood:** `initialize` stashes the connector token and environment process-wide — no network happens yet. The no-arg facade calls (`chat()`, `start()`, `hasResumableSession()`) reuse that config from any view controller. `chat()` resumes the persisted session when it's still valid; `start()` always discards. `hasResumableSession()` is a pure on-disk probe with no side effects.

*See [Integration guide › Quick start](../../../README.md#quick-start) and [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### Loading → chat / error via lifecycle streams — `Views/RootViewController.swift`

Don't poll for "is it connected yet" — subscribe to the three lifecycle streams on `client`. The tasks are tied to the **client**, not the session, so they keep working across in-place start-new on the same client:

The SDK signals:

```swift
client.events            // AsyncStream<MessagingEvent> — .sessionStart, .disconnected, etc.

client.connectionStatus  // AsyncStream<ConnectionStatus> — .connecting / .connected / .reconnecting / .failed

client.sessionState      // AsyncStream<SessionState> — .isReady flips true when the session can send
```

In a view controller:

```swift
private func configureAndStart(forceFresh: Bool) {
    // ...short-circuit if a live session already exists...

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
```

**Under the hood:** loading → chat is gated on `state.isReady` (or a `.sessionStart` event) and only fires *while still loading*, so a mid-chat reconnect never throws the user back to the loading screen. Errors are routed via `showError(_:)` only while loading, for the same reason — a transient blip after the chat is up just flips `connection` and recovers itself. `state.status == .restored` is how you know it's a warm resume.

*See [Integration guide › Connection & reconnect](../../../README.md#connection--reconnect).*

### Recoverable error screen — `Views/ErrorViewController.swift`

06's terminal state is not a latched failure flag — it's a `Screen.error` set by the lifecycle subscriptions above. "Go Back" routes to `.connect`:

The SDK signal that fed it:

```swift
session.client.sessionState   // .isError on session-creation failure
// (and .failed on connectionStatus, .disconnected(error) on events)
```

In a view controller:

```swift
final class ErrorViewController: UIViewController {
    private let message: String
    private let onBack: () -> Void

    init(message: String, onBack: @escaping () -> Void) {
        self.message = message
        self.onBack = onBack
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // ...icon + title + multiline `message` label...

        var conf = UIButton.Configuration.borderedProminent()
        conf.title = "Go Back"
        let back = UIButton(configuration: conf, primaryAction: UIAction { [weak self] _ in
            self?.onBack()
        })
        // ...pin in a stack...
    }
}
```

The error subtitles use `String(describing:)` on `PolyError` rather than `.localizedDescription`, because `PolyError` doesn't conform to `LocalizedError` (the default would just say "The operation couldn't be completed").

**Under the hood:** routing errors only while `.loading` means the error screen is recoverable by design — you can go back to connect and retry. If you want a non-recoverable terminal screen instead (the `04-Resilience` pattern), bind to `session.failureReason` directly.

*See [Integration guide › Terminal errors](../../../README.md#terminal-errors).*

### Resume-or-start picker — `Views/ConnectViewController.swift`

The connect screen picks button labels off `hasResumableSession()`:

The SDK call:

```swift
PolyMessaging.hasResumableSession()   // true if a stored session is within the timeout
```

In a view controller:

```swift
// RootViewController builds the connect screen with the resume probe:
private func showConnect() {
    screen = .connect
    let vc = ConnectViewController(
        hasActiveSession: session != nil,
        canResume: PolyMessaging.hasResumableSession(),
        onResume:   { [weak self] in self?.configureAndStart(forceFresh: false) },
        onStartNew: { [weak self] in self?.configureAndStart(forceFresh: true) }
    )
    transition(to: vc)
}

// ConnectViewController picks the label from what's resumable:
let primaryShowsResume = hasActiveSession || canResume
primaryButton.setTitle(primaryShowsResume ? "Resume Chat" : "Start Chat", for: .normal)
startNewButton.isHidden = !primaryShowsResume   // only show the secondary when resume is offered
```

**Under the hood:** `hasResumableSession()` is a side-effect-free on-disk check (no network), so it's safe to call every time the connect screen is shown — keeping the buttons honest as the user moves between connect / chat / connect.

*See [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### Nav-bar End vs back — `Views/RootViewController.swift`

The root owns both nav-bar buttons. The xmark **ends** the session (`session.end()`) after a confirm alert and returns to connect; the chevron **pauses** to connect *without* ending — the session stays alive for the user to come back to.

The SDK call:

```swift
session.end()   // permanent; the conversation cannot be resumed after this
```

In a view controller:

```swift
private func updateNavItems() {
    guard screen != .connect else {
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItem = nil
        return
    }
    navigationItem.leftBarButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chevron.left"),
        primaryAction: UIAction { [weak self] _ in self?.showConnect() }   // pause, don't end
    )
    let end = UIBarButtonItem(
        image: UIImage(systemName: "xmark.circle"),
        primaryAction: UIAction { [weak self] _ in self?.confirmEnd() }    // end for good
    )
    end.accessibilityLabel = "End Conversation"
    navigationItem.rightBarButtonItem = end
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
```

**Under the hood:** awaiting `end()` before clearing the local `session` ensures the server has acknowledged the teardown before the connect screen re-probes `hasResumableSession()` — otherwise you can get a phantom "Resume" button for a session that's already dead.

*See [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### In-place start-new — `Views/ChatViewController.swift`

When the chat ends, the chat-ended footer offers a new conversation without bouncing through the connect screen:

The SDK calls:

```swift
session.clearChat()                  // wipe the local transcript immediately
session.client.startNewSession()     // ends the current server session, starts a fresh one on the SAME client
```

In a view controller:

```swift
private func startNewConversationInPlace() {
    session.clearChat()
    Task { try? await session.client.startNewSession() }
}
```

**Under the hood:** `startNewSession()` reuses the existing client, so the lifecycle subscriptions in `RootViewController` (tied to that client) don't need re-arming — they flip the root back to `.chat` once the new session is ready. `ChatSession` detects the new session id and resets its latched flags, so the screen converges without leaving `.chat`.

*See [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### Delayed "Sending…" label — `Views/ChatViewController.swift`

The SDK already tracks real delivery (`.pending` → `.sent`); the ~500ms delay is purely app-side polish on *showing* the label, so fast confirmations never flash it:

The SDK signal:

```swift
ChatMessage.delivery   // .pending / .sent / .failed (.pending on optimistic send)
```

In a view controller:

```swift
private var sendingLabels: Set<UUID> = []
private var trackedPending: Set<UUID> = []

private func syncSendingLabels(_ messages: [ChatMessage]) {
    for case .user(let u) in messages where u.delivery == .pending && !trackedPending.contains(u.id) {
        trackedPending.insert(u.id)
        let id = u.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // Only show the label if the draft is STILL pending after 500ms.
            guard case .user(let current) = self.session.messages.first(where: { $0.id == id }),
                  current.delivery == .pending else { return }
            self.sendingLabels.insert(id)
            self.reconfigure(id: id)   // re-run cellProvider on this row
        }
    }
    // Drop ids that left .pending — keeps the sets in sync with reality.
    let stillPending = Set(messages.compactMap { msg -> UUID? in
        if case .user(let u) = msg, u.delivery == .pending { return u.id }
        return nil
    })
    sendingLabels.formIntersection(stillPending)
    trackedPending.formIntersection(stillPending)
}

private func reconfigure(id: UUID) {
    var snapshot = dataSource.snapshot()
    let item = Row.message(id)
    guard snapshot.itemIdentifiers.contains(item) else { return }
    snapshot.reconfigureItems([item])
    dataSource.apply(snapshot, animatingDifferences: false)
}
```

**Under the hood:** this only gates *display* — the SDK still reports `.pending` immediately and `.sent` the moment the server confirms. The bubble is in `messages` from the first frame either way; the label is the only thing this code controls.

*See [Integration guide › Delivery state & retry](../../../README.md#delivery--read-state).*

### Retry removes the failed draft, then re-sends — `Views/ChatViewController.swift`

A failed optimistic message stays in `messages` as a real draft keyed by its `draftId`. Retry drops the stale bubble first, then re-sends the text:

The SDK calls:

```swift
session.removeMessage(draftId:)   // drop the failed optimistic draft from messages
session.send(_:)                  // re-send as a fresh draft (new id)
```

In a view controller (inside the diffable data source's cell provider):

```swift
cell.onRetry = { [weak self] text in
    if let draftId = self?.draftId(for: id) {
        self?.session.removeMessage(draftId: draftId)
    }
    Task { try? await self?.session.send(text) }
}

private func draftId(for id: UUID) -> String? {
    guard case .user(let u) = session.messages.first(where: { $0.id == id }) else { return nil }
    return u.draftId
}
```

**Under the hood:** without `removeMessage`, retrying would leave a "Failed" bubble next to the new attempt — `send()` always creates a fresh draft id rather than mutating the old one. Dropping the failed draft first is what keeps the transcript clean.

*See [Integration guide › Delivery state & retry](../../../README.md#delivery--read-state).*

> **Streaming:** agent replies grow token-by-token by default (`Configuration.streamingEnabled: true` — ChatGPT-style). The chat's diffable data source uses `snapshot.reconfigureItems(...)` on the agent message's id every time `$messages` re-publishes, so the cell re-runs with the longer text and the table animates the height change. See the root README's [*Streaming*](../../../README.md#streaming) section and [`07-Playground`](../07-Playground/) for a live toggle.

## What this example skips

- runtime configuration knobs (`DevSettings`), raw transport tap, live diagnostics, event log, message timestamps → [`07-Playground/`](../07-Playground/)

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/06-FullReference/`](../../SwiftUI/06-FullReference/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
