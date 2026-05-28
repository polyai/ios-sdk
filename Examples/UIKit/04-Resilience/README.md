# 04-Resilience (UIKit)

Device-offline banner, pre-handshake loading skeleton, and a full-screen terminal-error overlay on top of [`03-RichContent`](../03-RichContent/).

- **Interface:** Storyboard (`Main.storyboard`) plus programmatic banners/overlays.
- **Lifecycle:** `AppDelegate` (`@main`) + `SceneDelegate`.

## Run it

```bash
open ResilienceUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your API key in `AppDelegate.swift` (currently `"YOUR_API_KEY"`).

## What this example demonstrates

- Track device connectivity with `NWPathMonitor` independently of the SDK's socket state
- Stack a red `OfflineBanner` above the yellow reconnect bar in a single `UIStackView`
- Gate a pulsing `LoadingSkeleton` on `!session.isReady && session.messages.isEmpty`
- Add a `TerminalErrorScreen` overlay LAST so it covers the full bounds when `session.failureReason` is non-nil
- Recover via `session.client.resume()` from the overlay's button

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them as one concrete view controller.

## How it works

Each subsection leads with **the SDK call** (one or a few lines — the actual API), then shows **how it's wired into a view controller**.

### Device-offline banner — `Components/OfflineBanner.swift`

Track the OS network path separately from the SDK's socket and stack a red bar above the yellow reconnect bar:

The SDK signal:

```swift
session.$connection   // Combine publisher — .idle / .connecting / .open / .closing / .closed / .reconnecting / .failed
```

`isOnline` is your own state, sourced from `NWPathMonitor`:

```swift
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "poly.example.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
```

In a view controller:

```swift
final class ChatViewController: UIViewController {
    private let network = NetworkMonitor()
    private let bannerStack = UIStackView()        // collapses hidden arranged subviews
    private let offlineBanner = OfflineBanner()    // red, OS-level
    private let connectionBanner = UIView()        // yellow, SDK reconnect

    private func bind() {
        // ...other sinks...

        session.$connection
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                if case .reconnecting = status {
                    self?.connectionBanner.isHidden = false
                    self?.connectionSpinner.startAnimating()
                } else {
                    self?.connectionBanner.isHidden = true
                    self?.connectionSpinner.stopAnimating()
                }
            }
            .store(in: &bag)

        network.$isOnline
            .receive(on: RunLoop.main)
            .sink { [weak self] online in self?.offlineBanner.update(isOnline: online) }
            .store(in: &bag)
    }
}
```

Both banners are arranged subviews of a vertical `UIStackView` pinned to the safe-area top. A stack collapses hidden arranged subviews, so when neither is showing the table reaches the top with no reserved padding.

**Under the hood:** when the OS reports `path.status != .satisfied`, the SDK's reachability watcher drops its dead socket within ~100ms and `connection` flips to `.reconnecting`. The two banners measure different things — the offline pill is the device, the reconnect pill is the socket — so it's fine (and meaningful) to show both.

*See [Integration guide › Connection & reconnect](../../../README.md#connection--reconnect).*

### Loading skeleton — `Components/LoadingSkeleton.swift`

Show pulsing placeholder rows only while the WebSocket is opening for the first time. Warm resumes already have messages in memory, so they skip the skeleton.

The SDK signals:

```swift
session.$isReady    // false until the SDK has finished its handshake and can send
session.$messages   // non-empty on warm resume → skip the skeleton entirely
```

In a view controller:

```swift
session.$isReady
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in self?.updateSkeletonVisibility() }
    .store(in: &bag)

// (the $messages sink, used to drive `render()`, also calls updateSkeletonVisibility())

private func updateSkeletonVisibility() {
    // Show the skeleton while the WebSocket is still opening AND we have
    // nothing to render. On warm resume the prior messages are already in
    // memory, so we skip the skeleton entirely.
    let show = !session.isReady && session.messages.isEmpty
    skeleton.isHidden = !show
    tableView.isHidden = show
}
```

The skeleton view itself is a vertical `UIStackView` of three rounded grey rows; the pulse uses `UIView.animate(..., options: [.repeat, .autoreverse, .curveEaseInOut])` and is started/stopped from `didMoveToWindow` and `isHidden`.

**Under the hood:** `isReady` stays `false` until the REST + WebSocket handshake completes and the session can send; the SDK flips it to `true` the moment a session id is in hand. On a cold relaunch where there's a stored session within the timeout, `messages` is hydrated from the cache before `isReady` flips — the `messages.isEmpty` half of the gate is what skips the skeleton in that path.

> **Streaming:** agent replies grow token-by-token by default (`Configuration.streamingEnabled: true` — ChatGPT-style). Set `streamingEnabled: false` to render completed bubbles only. See the root README's [*Streaming*](../../../README.md#streaming) section and [`07-Playground`](../07-Playground/) for a live toggle.

*See [Integration guide › Loading & empty states](../../../README.md#loading--empty-states).*

### Terminal error overlay — `Views/TerminalErrorScreen.swift`

When the SDK has given up reconnecting, show a full-screen overlay with one big retry button. The chat is useless in this state until the user explicitly retries.

The SDK calls:

```swift
session.$failureReason    // Combine publisher of PolyError? — non-nil after reconnect budget exhausted
session.client.resume()   // re-arm the connection from the overlay's button
```

In a view controller:

```swift
private let terminalErrorScreen = TerminalErrorScreen()
private var endButtonRef: UIBarButtonItem?   // captured in viewDidLoad so we can restore it

private func layoutTerminalErrorScreen() {
    // The overlay is added LAST so it sits above every other subview and
    // covers the whole bounds (including banners + nav area) when shown.
    terminalErrorScreen.isHidden = true
    view.addSubview(terminalErrorScreen)
    NSLayoutConstraint.activate([
        terminalErrorScreen.topAnchor.constraint(equalTo: view.topAnchor),
        terminalErrorScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        terminalErrorScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        terminalErrorScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
}

private func bind() {
    // ...other sinks...

    session.$failureReason
        .receive(on: RunLoop.main)
        .sink { [weak self] reason in
            guard let self else { return }
            if let reason {
                self.terminalErrorScreen.configure(reason: reason) { [weak self] in
                    Task { try? await self?.session.client.resume() }
                }
                self.terminalErrorScreen.isHidden = false
                self.navigationItem.rightBarButtonItem = nil   // hide End while overlay is up
            } else {
                self.terminalErrorScreen.isHidden = true
                if !self.session.hasEnded {
                    self.navigationItem.rightBarButtonItem = self.endButtonRef
                }
            }
        }
        .store(in: &bag)
}
```

The overlay uses `String(describing: reason)` for the subtitle — `PolyError` doesn't conform to `LocalizedError`, so `.localizedDescription` would just say "The operation couldn't be completed". `String(describing:)` gives the case name (`auth(unauthorized)`, `session(sessionExpired)`, etc.) which is far more useful.

**Under the hood:** `failureReason` is set only after the SDK's exponential-backoff reconnect ladder (with jitter) is exhausted, or on a terminal session error (auth, session-expired, session-ended). Transient blips don't trip it — those just flip `connection` to `.reconnecting` and back. That's why this overlay is full-screen and gated on `failureReason` rather than on `connection`.

*See [Integration guide › Terminal errors](../../../README.md#terminal-errors).*

## Try this in the simulator

| Action | What you should see |
|---|---|
| Toggle airplane mode mid-chat | Red offline banner; messages stay composable; toggle off → yellow reconnect banner → cleared |
| Kill network during cold launch | Loading skeleton → eventually terminal-error overlay → tap "Reconnect" |
| Cold launch with a stored session within ~10 min | No skeleton → restored messages render immediately |

## What this example skips

- live agent handoff → [`05-Handoff/`](../05-Handoff/)
- resume / start-new on a dedicated connect screen, in-place restart → [`06-FullReference/`](../06-FullReference/)
- runtime configuration, raw transport, diagnostics → [`07-Playground/`](../07-Playground/)

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/04-Resilience/`](../../SwiftUI/04-Resilience/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
