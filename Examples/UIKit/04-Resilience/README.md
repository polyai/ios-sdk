# 04-Resilience (UIKit)

Offline banner, loading skeleton, and a terminal error screen on top of [`03-RichContent`](../03-RichContent/). UIKit + Storyboard counterpart of [`../../SwiftUI/04-Resilience/`](../../SwiftUI/04-Resilience/).

## Run it

```bash
open ResilienceUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## New in this level

- `LoadingSkeleton.swift` — pulsing placeholder rows while the socket opens.
- `NetworkMonitor.swift` — `NWPathMonitor` wrapper exposing `@Published isOnline`.
- `OfflineBanner.swift` — device-offline banner that stacks above the reconnect banner.
- `TerminalErrorScreen.swift` — full-screen overlay with a Reconnect button once reconnects are exhausted.

Everything else is inherited from [`03-RichContent`](../03-RichContent/); see its README.

## How it works

### Network monitor — `NetworkMonitor.swift`

A plain `ObservableObject` wrapping `NWPathMonitor`. Started on a dedicated background queue (NWPathMonitor requires it); the path-update handler hops back to the main queue before mutating `@Published var isOnline`, so Combine subscribers in the view controller see a consistent thread.

**Under the hood:** This tracks the OS network path (`NWPathMonitor`) — an app concern that's separate from the SDK's own socket reconnect state, so device-offline and socket-reconnecting are reported independently.

```swift
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "poly.example.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
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

### Offline banner — `OfflineBanner.swift`

A `UIView` holding an SF Symbol + label; it shows or hides itself via `update(isOnline:)`. Stacked above the SDK's reconnect banner so device-offline vs socket-reconnecting are visually distinct.

**Under the hood:** When the OS reports offline, the SDK drops the dead socket within ~100ms and surfaces `.reconnecting`; this banner reflects the OS path while the reconnect banner reflects the SDK's socket state, so both can show at once.

```swift
network.$isOnline
    .receive(on: RunLoop.main)
    .sink { [weak self] online in self?.offlineBanner.update(isOnline: online) }
    .store(in: &bag)
```

*See [Build your own UI › Connection & reconnect](../../../README.md#connection--reconnect).*

### Loading skeleton — `LoadingSkeleton.swift`

Three pulsing gray rounded rows shown while the WebSocket is still opening. The gate is `!session.isReady && session.messages.isEmpty` — skip the skeleton on warm resume where prior messages are already in memory. Animation uses `UIView.animate(..., options: [.repeat, .autoreverse, ...])`.

**Under the hood:** `isReady` stays `false` until the SDK finishes the handshake and the session can send; it flips to `true` once ready, which clears the skeleton.

```swift
private func updateSkeletonVisibility() {
    let show = !session.isReady && session.messages.isEmpty
    skeleton.isHidden = !show
    tableView.isHidden = show
}
```

*See [Build your own UI › Loading & empty states](../../../README.md#loading--empty-states).*

### Terminal error screen — `TerminalErrorScreen.swift`

A `UIView` overlay added LAST to the view hierarchy so it covers every other subview when shown. Bound to `session.failureReason`: when non-nil, the overlay appears with an SF Symbol + reason text + a single "Reconnect" button that calls `session.client.resume()`. `PolyError` doesn't conform to `LocalizedError`, so the subtitle uses `String(describing: reason)`.

**Under the hood:** `failureReason` is non-nil only after the SDK's auto-reconnect (exponential backoff + jitter) is exhausted — a terminal state needing the user, which is why Reconnect calls `client.resume()`.

```swift
session.$failureReason
    .receive(on: RunLoop.main)
    .sink { [weak self] reason in
        guard let self = self else { return }
        if let reason = reason {
            self.terminalErrorScreen.configure(reason: reason) { [weak self] in
                Task { try? await self?.session.client.resume() }
            }
            self.terminalErrorScreen.isHidden = false
            // …hide the End button while the overlay covers the chat
        } else {
            self.terminalErrorScreen.isHidden = true
            // …restore the End button if the chat hasn't ended
        }
    }
    .store(in: &bag)
```

*See [Build your own UI › Terminal errors](../../../README.md#terminal-errors).*

## Try this in the simulator

| Action | What you should see |
|---|---|
| Toggle airplane mode mid-chat | Red offline banner; messages queue; toggle off → yellow reconnect banner → cleared |
| Kill network during cold launch | Loading skeleton → eventually terminal error → tap Reconnect |
| Cold launch with existing session within ~10 min | Brief skeleton → restored messages render |

## What this example skips

- live agent handoff → [`../05-Handoff/`](../05-Handoff/)

## Copy these into your app

The views in this folder are copy-paste ready — they use only **public SDK types**, so they drop into any app that has the package. Add the package (root [README → Install](../../../README.md#install)) and drive these views from `ChatSession`: root [README → "Build your own UI"](../../../README.md#build-your-own-ui).

---

**Counterpart:** SwiftUI version at [`Examples/SwiftUI/04-Resilience/`](../../SwiftUI/04-Resilience/).

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the SwiftUI counterpart. See `SKILL.md §12`.
