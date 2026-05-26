# 01-Hello (UIKit)

The smallest possible chat, in UIKit + Storyboard: initialize the SDK, render messages in a table, send one. The UIKit counterpart of [`../../SwiftUI/01-Hello/`](../../SwiftUI/01-Hello/).

- **Interface:** Storyboard (`Main.storyboard`)
- **Lifecycle:** `AppDelegate` (`@main`) + `SceneDelegate` (scene-based)

## Run it

```bash
open HelloUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Connector token + dev environment are pre-filled in `AppDelegate.swift` — swap to your token + a cluster (or `.production`) before shipping.

## How it works

### Initialize once at app launch — `AppDelegate.swift`

```swift
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        PolyMessaging.initialize(.init(
            connectorToken: "XOVkv…",
            environment: .dev
        ))
        return true
    }
}
```

After this, `PolyMessaging.chat()` works from any view controller with no arguments.

**Under the hood:** `initialize` just stashes your connector token and environment process-wide — no network happens yet. The work starts when you call `chat()`.

*See [Quick start › drop in our UI](../../../README.md#quick-start--drop-in-our-ui).*

### Get a session and render messages — `ChatViewController.swift`

`ChatSession` is an `ObservableObject`; its `@Published` properties are Combine publishers, so UIKit binds with `.sink` — no SwiftUI required. Messages render through a diffable data source keyed by `ChatMessage.id`.

```swift
private var session: ChatSession!
private var bag = Set<AnyCancellable>()

override func viewDidLoad() {
    super.viewDidLoad()
    session = PolyMessaging.chat()        // one session per chat surface
    configureDataSource()
    bind()
}

private func bind() {
    session.$messages
        .receive(on: RunLoop.main)
        .sink { [weak self] messages in self?.render(messages) }
        .store(in: &bag)
}
```

**Streaming is on by default** — `Configuration.streamingEnabled` defaults to `true`, so agent replies grow token-by-token (ChatGPT-style). The `render(_:)` snapshot above calls `reconfigureItems` on existing IDs, so each cell re-renders as the agent message's text grows. To switch to complete-message bubbles instead, set `streamingEnabled: false` in `AppDelegate.swift`'s `Configuration`. See the root README's [*Streaming*](../../../README.md#streaming) section.

**Under the hood:** `chat()` returns a `ChatSession` and runs the whole REST + WebSocket handshake, agent-join, and resume-or-create for you; `isReady` flips true once it's connected. `messages` is the SDK-maintained transcript (`.user`/`.agent`/`.system`) that republishes on every change, so each `.sink` just hands you the full list to render.

*See [Build your own UI › The core pattern](../../../README.md#the-core-pattern-render-messages-yourself).*

### Send a message — `ChatViewController.swift`

```swift
@IBAction func sendTapped(_ sender: Any) {
    guard let text = inputField.text, !text.isEmpty else { return }
    inputField.text = ""
    Task { try? await session.send(text) }
}
```

`tableView`, `inputField`, and `sendButton` are `@IBOutlet`s wired in `Main.storyboard`.

**Under the hood:** `send(text)` is optimistic — the bubble appears in `messages` immediately while the SDK manages delivery and the server echo behind the scenes. `ChatSession` is `@MainActor`, so call it from the main thread.

*See [Build your own UI › The core pattern](../../../README.md#the-core-pattern-render-messages-yourself).*

### Catch a bad connector token — `ChatViewController.swift`

If `connectorToken` is wrong or expired the chat can't ever connect — without surfacing that, the app would sit silently with an empty table view. `session.failureReason` is non-nil whenever the SDK hits a terminal failure it can't auto-recover from (most commonly an invalid token), so sink it and present a `UIAlertController`:

```swift
session.$failureReason
    .receive(on: RunLoop.main)
    .compactMap { $0 }
    .sink { [weak self] reason in self?.presentFailureAlert(reason: reason) }
    .store(in: &bag)

private func presentFailureAlert(reason: PolyError) {
    let alert = UIAlertController(
        title: "Couldn't connect",
        message: String(describing: reason),
        preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
        Task { try? await self?.session.client.resume() }
    })
    present(alert, animated: true)
}
```

`String(describing:)` is intentional — `PolyError` doesn't conform to `LocalizedError`, so `.localizedDescription` is the generic "The operation couldn't be completed". `String(describing:)` gives the case name (`auth(unauthorized)`) which is far more useful in an example.

**Under the hood:** `failureReason` is fed by both `client.connectionStatus.failed` (reconnect budget exhausted, session expired) and the initial-connect path that catches an unauthorized REST response and flags `sessionState.hasInvalidConnectorToken`. Either way you get a single source of truth for "the chat can't recover from this".

## Storyboard note

`Main.storyboard` hard-codes `customModule="HelloUIKit"` on the view controller. If you rename the Xcode target, open `Main.storyboard` in Interface Builder, select the View Controller, and update the **Module** field in the Identity Inspector to match — or set it to "None" to let UIKit resolve the class from any module.

## What this example skips

- typing indicator, connection banner, delivery state, suggestions, end button → [`02-Standard/`](../02-Standard/)
- attachments, URL cards, call actions → [`03-RichContent/`](../03-RichContent/)
- offline detection, terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

## Copy this into your app

The views in this folder are copy-paste ready — they use only **public SDK types**, so they drop into any app that has the package. Add the package and follow the root [README → "Build your own UI"](../../../README.md#build-your-own-ui).

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/01-Hello/`](../../SwiftUI/01-Hello/)
- **Add the package:** root [README → Install](../../../README.md#install)
- **Build your own UI:** root [README → Build your own UI](../../../README.md#build-your-own-ui)

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the SwiftUI counterpart. See `SKILL.md §12`.
