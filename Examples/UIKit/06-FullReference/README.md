# 06-FullReference (UIKit)

The complete UIKit reference app — the counterpart to
[`SwiftUI/06-FullReference`](../../SwiftUI/06-FullReference/) and the **canonical
source for [`Examples/Components/`](../../Components/)**. 06 is the only level
with the full `connect → loading → chat → error` flow, built entirely
programmatically (no storyboard). It builds on [`05-Handoff`](../05-Handoff/),
folding every feature from 02–05 into one production-shaped app and adding the
multi-screen lifecycle shell, resume/start-new flow, and recoverable error
handling that the lighter levels skip.

Because 06 is the most-extensive example, this README is both a **complete index
of every feature the ladder demonstrates** (section 3) and a deep dive into the
**production-only patterns** that only 06 has (section 4).

## Run it

```bash
open FullReferenceUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

No storyboard — the scene is built programmatically: `SceneDelegate` wraps a
`RootViewController` in a `UINavigationController`, and `RootViewController`
swaps the connect / loading / chat / error child controllers. (UIKit 01–05 are
storyboard-based; only 06 and 07 are not.)

## Everything 06 demonstrates

06 carries the entire feature set of the ladder. Each row links the matching
"Build your own UI" section in the root README and notes the level it first
appeared, so this table doubles as a complete index. The rendering views that
power these features live in [`Components/`](Components/) (the canonical set) and
[`Helpers/`](Helpers/).

| Feature | Where in 06 | First seen | Root reference |
|---|---|---|---|
| Typing indicator | `TypingDotsView` + `session.$isAgentTyping` — `Views/ChatViewController.swift` | 02-Standard | [Typing](../../../README.md#typing) |
| Suggestions / quick replies | `SuggestionsCell` + `SuggestionsView` — `Views/ChatViewController.swift`, `Components/SuggestionsView.swift` | 02-Standard | [Suggestions (quick replies)](../../../README.md#suggestions-quick-replies) |
| Delivery state + retry | `MessageCell` delivery + `onRetry` — `Components/MessageCell.swift` | 02-Standard | [Delivery state & retry](../../../README.md#delivery-state--retry) |
| Image attachments | `AttachmentCarouselView` — `Components/AttachmentCarouselView.swift` | 03-RichContent | [Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons) |
| URL cards | `URLCardView` — `Components/URLCardView.swift` | 03-RichContent | [Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons) |
| Call actions (`tel:`) | `CallActionsRow` — `Components/CallActionsRow.swift` | 03-RichContent | [Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons) |
| Rich text / Markdown | `MessageCell.renderMarkdown` — `Components/MessageCell.swift` | 03-RichContent | [Rich text & links](../../../README.md#rich-text--links) |
| Connection / reconnect bar | `connectionBanner` + `session.$connection` — `Views/ChatViewController.swift` | 02-Standard | [Connection & reconnect](../../../README.md#connection--reconnect) |
| Device offline banner | `OfflineBanner` + `Helpers/NetworkMonitor` — `Components/OfflineBanner.swift` | 04-Resilience | [Connection & reconnect](../../../README.md#connection--reconnect) |
| Live-agent handoff | `MessageCell` agent styling — `Components/MessageCell.swift` | 05-Handoff | [Live agent handoff](../../../README.md#live-agent-handoff) |
| Loading skeleton / empty state | `LoadingSkeleton` — `Components/LoadingSkeleton.swift` | 04-Resilience | [Loading & empty states](../../../README.md#loading--empty-states) |

For how each of these works at the SDK level, read the level it first appeared
in — those READMEs are the per-feature explanations. The rest of this README
covers what is genuinely new in 06.

## What's unique to 06 (the production layer)

These patterns exist only in 06 (and its SwiftUI twin). They are the difference
between a single chat screen (02–05) and a real app that owns a session across a
multi-screen lifecycle.

### The screen-state machine + child-VC containment — `Views/RootViewController.swift`

**Under the hood:** `RootViewController` owns the single `ChatSession` and a
`Screen` enum, swapping one child view controller in at a time. The connect /
loading / chat / error screens never each talk to the SDK — only the root does —
so the session survives every screen transition, including an in-place
start-new.

```swift
private enum Screen { case connect, loading, chat, error }

private var session: ChatSession?
private var screen: Screen = .connect
private var current: UIViewController?

private func transition(to child: UIViewController) {
    if let current {
        current.willMove(toParent: nil)
        current.view.removeFromSuperview()
        current.removeFromParent()
    }
    addChild(child)
    view.addSubview(child.view)
    // …pin child.view to all edges…
    child.didMove(toParent: self)
    current = child
    updateNavItems()
}
```

— `Views/RootViewController.swift`

### Lifecycle subscriptions that drive the transitions — `Views/RootViewController.swift`

**Under the hood:** the loading → chat / error transitions are driven off the
client's `events`, `connectionStatus`, and `sessionState` streams — not off the
`ChatSession`'s `@Published` props. The tasks are tied to the **client**, not the
session, so they keep working across an in-place start-new on the same client.

```swift
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
        for await state in client.sessionState {
            guard let self else { return }
            if state.status == .restored { self.wasResumed = true }
            if state.isReady, self.screen == .loading || self.screen == .error { self.showChat() }
            if state.isError, self.screen == .loading {
                self.showError(state.errorMessage ?? "Couldn't start the session.")
            }
        }
    })
    // …a third task watches client.connectionStatus for .failed during loading…
}
```

— `Views/RootViewController.swift`

### Resume-or-start on the connect screen — `Views/ConnectViewController.swift`

**Under the hood:** the connect screen probes `PolyMessaging.hasResumableSession()`
(a side-effect-free on-disk check) to decide whether to offer "Resume". The
primary button maps to `chat()` (resume the stored session if valid, else fresh)
and the secondary "Start New Chat" maps to `start()` (always fresh). Both paths
stay visible so host apps can copy the exact flow they need.

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

// configureAndStart picks chat() vs start() off the no-arg facade:
let s = forceFresh ? PolyMessaging.start() : PolyMessaging.chat()
session = s
showLoading()
subscribeLifecycle(to: s.client)
```

— `Views/RootViewController.swift`

The connection config was set once in `App/AppDelegate.swift` via
`PolyMessaging.initialize(...)`; every call site here uses the no-arg facade,
which reuses it.

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### The loading screen — `Views/LoadingViewController.swift`

**Under the hood:** a plain centered spinner shown while the session connects.
`RootViewController` swaps it for `ChatViewController` once `sessionState`
reports ready (`state.isReady`), or for `ErrorViewController` on failure.

```swift
private func showLoading() {
    screen = .loading
    transition(to: LoadingViewController())
}
```

— `Views/RootViewController.swift`

### The error screen + how errors route to it — `Views/ErrorViewController.swift`

**Under the hood:** 06's terminal state is a **recoverable** error screen driven
by connect/lifecycle failure, not by any latched failure flag. The lifecycle
subscriptions call `showError(_:)` when the session reports an error during
loading; the "Go Back" button returns to the connect screen so the user can
resume or start fresh.

```swift
private func showError(_ message: String) {
    screen = .error
    transition(to: ErrorViewController(message: message,
                                       onBack: { [weak self] in self?.showConnect() }))
}
```

```swift
// ErrorViewController is purely a message + a back button:
init(message: String, onBack: @escaping () -> Void) {
    self.message = message
    self.onBack = onBack
    super.init(nibName: nil, bundle: nil)
}
```

— `Views/RootViewController.swift`, `Views/ErrorViewController.swift`

### Nav-bar End vs back — `Views/RootViewController.swift`

**Under the hood:** the root owns both nav-bar buttons. The xmark **ends** the
session (`session.end()`) after a confirm alert and returns to connect; the
chevron **pauses** to connect *without* ending — the session stays alive so the
user can come back to the same conversation.

```swift
navigationItem.leftBarButtonItem = UIBarButtonItem(
    image: UIImage(systemName: "chevron.left"),
    primaryAction: UIAction { [weak self] _ in self?.showConnect() }   // pause, don't end
)
let end = UIBarButtonItem(
    image: UIImage(systemName: "xmark.circle"),
    primaryAction: UIAction { [weak self] _ in self?.confirmEnd() }    // end for good
)
```

```swift
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

— `Views/RootViewController.swift`

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### In-place Start-New (no screen change) — `Views/ChatViewController.swift`

**Under the hood:** when the chat ends, the chat-ended banner offers a new
conversation without bouncing through the connect screen. `clearChat()` wipes the
local transcript immediately; `startNewSession()` ends the current server-side
session and starts a fresh one on the **same** client — so the persistent
lifecycle subscriptions (tied to the client) flip the root back to chat once the
new session is ready.

```swift
private func startNewConversationInPlace() {
    session.clearChat()
    Task { try? await session.client.startNewSession() }
}
```

— `Views/ChatViewController.swift`

`RootViewController` does the same when "Start New Chat" is tapped on an already
live session: it spins up a fresh `ChatSession` on the existing client and calls
`existing.client.startNewSession()`.

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### Delayed "Sending…" label (≈500ms debounce) — `Views/ChatViewController.swift`

**Under the hood:** the SDK already tracks real delivery (`.pending` → `.sent`);
the ≈500ms delay is pure app-side polish on *showing* the label, so quick
confirmations never flash "Sending…". It doesn't change how or when the SDK
reports delivery.

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
    guard let self else { return }
    guard case .user(let current) = self.session.messages.first(where: { $0.id == id }),
          current.delivery == .pending else { return }
    self.sendingLabels.insert(id)
    self.reconfigure(id: id)
}
```

— `Views/ChatViewController.swift`

*See [Build your own UI › Delivery state & retry](../../../README.md#delivery-state--retry).*

### Retry removes the failed draft, then re-sends — `Views/ChatViewController.swift`

**Under the hood:** retrying a failed user message first drops the failed draft
via `session.removeMessage(draftId:)`, then sends the text again — so the
transcript never keeps a stale failed bubble alongside the new attempt.

```swift
cell.onRetry = { [weak self] text in
    if let draftId = self?.draftId(for: id) { self?.session.removeMessage(draftId: draftId) }
    Task { try? await self?.session.send(text) }
}
```

— `Views/ChatViewController.swift`

*See [Build your own UI › Delivery state & retry](../../../README.md#delivery-state--retry).*

## What it skips → where next

06 deliberately leaves out the developer-only surface. The next level adds it:

- **`DevSettings` runtime configuration**, a **raw-transport tap** for the live
  event stream, on-screen **diagnostics**, and **progressive streaming** →
  [`07-Playground`](../07-Playground/).

## Copy these into your app

The views here are copy-paste ready — they use only **public SDK types**, so they
drop into any app that has the package. Add it via
root [README → Install](../../../README.md#install), then follow
root [README → "Build your own UI"](../../../README.md#build-your-own-ui) to drive
the components from `ChatSession`.

---

**Cross-framework counterpart:** the SwiftUI twin of this app is
[`Examples/SwiftUI/06-FullReference/`](../../SwiftUI/06-FullReference/) — same
feature set, same connector-token wiring; only the UI binding differs.

When you change this example, update the matching snippets in the project
[`README.md`](../../../README.md) **and** the SwiftUI counterpart at
[`Examples/SwiftUI/06-FullReference/`](../../SwiftUI/06-FullReference/). See
`SKILL.md §12`.
