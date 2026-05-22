# 01-Hello

The smallest possible chat: initialize the SDK, render messages, send one.

## Run it

```bash
open HelloSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Connector token + dev environment are pre-filled in `HelloApp.swift`.

## How it works

### Initialize once at app launch — `HelloApp.swift`

```swift
@main
struct HelloApp: App {
    init() {
        PolyMessaging.initialize(.init(
            connectorToken: "XOVkv…",
            environment: .dev
        ))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

After this, `PolyMessaging.chat()` works from any view.

**Under the hood:** `initialize` just stashes your connector token and environment process-wide — no network happens yet. The work starts when you call `chat()`.

*See [Quick start › drop in our UI](../../../README.md#quick-start--drop-in-our-ui).*

### Get a session and render messages — `ContentView.swift`

```swift
@StateObject var session = PolyMessaging.chat()

List(session.messages) { message in
    Text(message.text ?? "")
}
```

`session.messages` is `@Published`. SwiftUI re-renders when it changes. `@StateObject` keeps one session per view lifecycle.

**Under the hood:** `chat()` returns a `ChatSession` and runs the whole REST + WebSocket handshake, agent-join, and resume-or-create for you; `isReady` flips true once it's connected. `messages` is the SDK-maintained transcript (`.user`/`.agent`/`.system`) that republishes on every change, so your list just re-renders.

*See [Build your own UI › The core pattern](../../../README.md#the-core-pattern-render-messages-yourself).*

### Send a message — `ContentView.swift`

```swift
Button("Send") {
    let text = input
    input = ""
    Task { try? await session.send(text) }
}
.disabled(input.isEmpty || session.hasEnded)
```

Sending stays available even while offline or reconnecting — gate only on `hasEnded` (and empty text), **not** on connection readiness. `send(_:)` is optimistic, so a message typed before the socket is up is queued and delivered once it connects. `hasEnded` becomes true after `session.end()`. (The UIKit twin makes the same choice.)

**Under the hood:** `send(text)` is optimistic — the bubble appears in `messages` immediately while the SDK manages delivery and the server echo behind the scenes. `ChatSession` is `@MainActor`, so call it from the main thread.

*See [Build your own UI › The core pattern](../../../README.md#the-core-pattern-render-messages-yourself).*

## What this example skips

- typing indicator, connection banner, delivery dots, suggestions, end button → [`02-Standard/`](../02-Standard/)
- attachments, URL cards, call actions → [`03-RichContent/`](../03-RichContent/)
- offline detection, terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

## Copy this into your app

The views in this folder are copy-paste ready — they use only **public SDK types**, so they drop into any app that has the package. Add the package and follow the root [README → "Build your own UI"](../../../README.md#build-your-own-ui).

---

- **UIKit counterpart:** [`Examples/UIKit/01-Hello/`](../../UIKit/01-Hello/)
- **Add the package:** root [README → Install](../../../README.md#install)
- **Build your own UI:** root [README → Build your own UI](../../../README.md#build-your-own-ui)

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the UIKit counterpart. See `SKILL.md §12`.
