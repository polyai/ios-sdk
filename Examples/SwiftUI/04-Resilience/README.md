# 04-Resilience

Offline banner, loading skeleton, and a terminal error screen on top of [`03-RichContent`](../03-RichContent/).

## Run it

```bash
open ResilienceSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## New in this level

- `Helpers/NetworkMonitor.swift` — `NWPathMonitor` wrapper exposing `@Published isOnline`.
- `Components/OfflineBanner.swift` — translucent-red "You're offline" banner (distinct from the reconnect pill).
- `Components/LoadingSkeleton.swift` — pulsing placeholder rows while the socket opens.
- `Views/TerminalErrorScreen.swift` — full-screen retry screen once reconnects are exhausted.

Everything else — rich content, suggestions, typing, the reconnect banner — is inherited from [`03-RichContent`](../03-RichContent/); see its README.

## How it works

### Network monitor — `Helpers/NetworkMonitor.swift`

A SwiftUI `ObservableObject` wrapping `NWPathMonitor`. Started on a dedicated background queue (NWPathMonitor requires it); `@MainActor` ensures `@Published` updates land on the main thread.

**Under the hood:** This tracks the OS network path (`NWPathMonitor`) — an app concern that's separate from the SDK's own socket reconnect state, so device-offline and socket-reconnecting are reported independently.

```swift
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "poly.example.NetworkMonitor")

    init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
```

*See [Build your own UI › Connection & reconnect](../../../README.md#connection--reconnect).*

### Offline banner — `Components/OfflineBanner.swift`

Takes `isOnline` and renders itself only when offline (above the connection banner). A translucent red bar so device-offline reads differently from the yellow socket-reconnecting banner.

**Under the hood:** When the OS reports offline, the SDK drops the dead socket within ~100ms and surfaces `.reconnecting`; this banner reflects the OS path while the connection banner reflects the SDK's socket state, so both can show at once.

```swift
struct OfflineBanner: View {
    let isOnline: Bool

    var body: some View {
        if !isOnline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text("You're offline").font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(.systemRed).opacity(0.18))
            .foregroundColor(.red)
        }
    }
}
```

Wired in `Views/ContentView.swift`:

```swift
OfflineBanner(isOnline: network.isOnline)
ConnectionBanner(status: session.connection)
```

*See [Build your own UI › Connection & reconnect](../../../README.md#connection--reconnect).*

### Loading skeleton — `Components/LoadingSkeleton.swift`

Pulsing gray rows shown while the WebSocket is still opening. The gate (in `Views/ContentView.swift`) is `!isReady && messages.isEmpty` — skip the skeleton on warm resume where prior messages are already in memory.

**Under the hood:** `isReady` stays `false` until the SDK finishes the handshake and the session can send; it flips to `true` once ready, which clears the skeleton.

```swift
if !session.isReady && session.messages.isEmpty {
    LoadingSkeleton()
} else {
    LazyVStack(spacing: 8) {
        ForEach(session.messages) { message in
            MessageBubbleView(message: message)
                .id(message.id)
        }
    }
    // …
}
```

*See [Build your own UI › Loading & empty states](../../../README.md#loading--empty-states).*

### Terminal error screen — `Views/TerminalErrorScreen.swift`

Replaces the whole chat surface when `session.failureReason != nil`. Once the SDK has exhausted its reconnect budget, the chat UI is useless until the user explicitly retries.

**Under the hood:** `failureReason` is non-nil only after the SDK's auto-reconnect (exponential backoff + jitter) is exhausted — a terminal state needing the user, which is why retry calls `client.resume()`.

```swift
if let reason = session.failureReason {
    TerminalErrorScreen(reason: reason) {
        Task { try? await session.client.resume() }
    }
} else {
    mainChat
}
```

`PolyError` doesn't conform to `LocalizedError`, so the screen uses `String(describing: reason)` for the subtitle.

*See [Build your own UI › Terminal errors](../../../README.md#terminal-errors).*

## Try this in the simulator

| Action | What you should see |
|---|---|
| Toggle airplane mode mid-chat | Red offline banner; messages queue; toggle off → reconnect banner → cleared |
| Kill network during cold launch | Loading skeleton → eventually terminal error → tap retry |
| Cold launch with existing session within ~10 min | Brief skeleton → restored messages render |

## What this example skips

- live agent handoff → [`05-Handoff/`](../05-Handoff/)

## Copy these into your app

The views in this folder are copy-paste ready — they use only **public SDK types**, so they drop into any app that has the package. Add the package (root [README → Install](../../../README.md#install)) and drive these views from `ChatSession`: root [README → "Build your own UI"](../../../README.md#build-your-own-ui).

---

**Counterpart:** UIKit version at [`Examples/UIKit/04-Resilience/`](../../UIKit/04-Resilience/).

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the UIKit counterpart. See `SKILL.md §12`.
