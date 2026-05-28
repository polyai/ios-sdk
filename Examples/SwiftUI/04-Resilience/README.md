# 04-Resilience (SwiftUI)

Device-offline banner, pre-handshake loading skeleton, and a full-screen terminal-error screen on top of [`03-RichContent`](../03-RichContent/).

## Run it

```bash
open ResilienceSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your API key in `ResilienceApp.swift` (currently `"YOUR_API_KEY"`).

## What this example demonstrates

- Track device connectivity with `NWPathMonitor` independently of the SDK's socket state
- Stack a red "offline" banner above the SDK's yellow "reconnecting" banner
- Gate a pulsing loading skeleton on `!session.isReady && session.messages.isEmpty`
- Replace the entire chat surface with a full-screen retry screen when `session.failureReason` is non-nil
- Recover via `session.client.resume()` from the terminal screen

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them as one concrete view.

## How it works

Each subsection leads with **the SDK call** (one or a few lines — the actual API), then shows **how it's wired into a view**.

### Device-offline banner — `Components/OfflineBanner.swift`

Track the OS network path separately from the SDK's socket and render a red bar above the yellow reconnect banner:

The SDK call:

```swift
session.connection   // .idle / .connecting / .open / .closing / .closed / .reconnecting / .failed — fires on every transition
```

`isOnline` is your own state, sourced from `NWPathMonitor`:

```swift
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "poly.example.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
```

In a view:

```swift
struct ContentView: View {
    @StateObject var session = PolyMessaging.chat()
    @StateObject var network = NetworkMonitor()

    var body: some View {
        VStack(spacing: 0) {
            // OS-level offline pill (red) stacks ABOVE the SDK's reconnect pill (yellow).
            // Both can be visible simultaneously.
            OfflineBanner(isOnline: network.isOnline)
            ConnectionBanner(status: session.connection)

            // ...message list + composer...
        }
    }
}
```

**Under the hood:** when the OS reports `path.status != .satisfied`, the SDK's reachability watcher drops its dead socket within ~100ms and `session.connection` flips to `.reconnecting`. The two banners measure different things — the offline pill is the device, the reconnect pill is the socket — so it's fine (and meaningful) to show both.

*See [Integration guide › Connection & reconnect](../../../README.md#connection--reconnect).*

### Loading skeleton — `Components/LoadingSkeleton.swift`

Show pulsing placeholder rows only while the WebSocket is opening for the first time. Warm resumes already have messages in memory, so they skip the skeleton.

The SDK signals:

```swift
session.isReady        // false until the SDK has finished its handshake and can send
session.messages       // non-empty on warm resume → skip the skeleton entirely
```

In a view:

```swift
ScrollViewReader { proxy in
    ScrollView {
        if !session.isReady && session.messages.isEmpty {
            LoadingSkeleton()
        } else {
            LazyVStack(spacing: 8) {
                ForEach(session.messages) { message in
                    MessageBubbleView(message: message, /* ... */)
                        .id(message.id)
                }
                if session.isAgentTyping {
                    TypingIndicator(avatarUrl: session.lastAgentMessage?.avatarUrl)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
```

**Under the hood:** `isReady` stays `false` until the REST + WebSocket handshake completes and the session can send; the SDK flips it to `true` the moment a session id is in hand. On a cold relaunch where there's a stored session within the timeout, `messages` is hydrated from the cache before `isReady` flips — the `messages.isEmpty` half of the gate is what skips the skeleton in that path.

> **Streaming:** agent replies grow token-by-token by default (`Configuration.streamingEnabled: true` — ChatGPT-style). Set `streamingEnabled: false` to render completed bubbles only. See the root README's [*Streaming*](../../../README.md#streaming) section and [`07-Playground`](../07-Playground/) for a live toggle.

*See [Integration guide › Loading & empty states](../../../README.md#loading--empty-states).*

### Terminal error screen — `Views/TerminalErrorScreen.swift`

Once the SDK has given up reconnecting, replace the whole chat with a single retry button. The chat is useless in this state until the user explicitly retries.

The SDK calls:

```swift
session.failureReason     // PolyError? — non-nil after the reconnect budget is exhausted
session.client.resume()   // re-arm the connection from the retry button
```

In a view:

```swift
var body: some View {
    NavigationView {
        Group {
            if let reason = session.failureReason {
                TerminalErrorScreen(reason: reason) {
                    Task { try? await session.client.resume() }
                }
            } else {
                mainChat   // banners + message list + composer
            }
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !session.hasEnded && session.failureReason == nil {
                    Button("End Chat") { Task { try? await session.end() } }
                }
            }
        }
    }
}
```

The screen itself uses `String(describing: reason)` for the subtitle — `PolyError` doesn't conform to `LocalizedError`, so `.localizedDescription` would just say "The operation couldn't be completed". `String(describing:)` gives the case name (`auth(unauthorized)`, `session(sessionExpired)`, etc.) which is far more useful.

**Under the hood:** `failureReason` is set only after the SDK's exponential-backoff reconnect ladder (with jitter) is exhausted, or on a terminal session error (auth, session-expired, session-ended). Transient blips don't trip it — those just flip `connection` to `.reconnecting` and back. That's why this screen is full-screen and gated on `failureReason` rather than on `connection`.

*See [Integration guide › Terminal errors](../../../README.md#terminal-errors).*

## Try this in the simulator

| Action | What you should see |
|---|---|
| Toggle airplane mode mid-chat | Red offline banner; messages stay composable; toggle off → yellow reconnect banner → cleared |
| Kill network during cold launch | Loading skeleton → eventually terminal-error screen → tap "Try Again" |
| Cold launch with a stored session within ~10 min | No skeleton → restored messages render immediately |

## What this example skips

- live agent handoff → [`05-Handoff/`](../05-Handoff/)
- resume / start-new on a dedicated connect screen, in-place restart → [`06-FullReference/`](../06-FullReference/)
- runtime configuration, raw transport, diagnostics → [`07-Playground/`](../07-Playground/)

---

- **UIKit counterpart:** [`Examples/UIKit/04-Resilience/`](../../UIKit/04-Resilience/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
