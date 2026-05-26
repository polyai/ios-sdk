# 07-Playground (UIKit)

The most extensive example in the ladder: a developer playground for protocol and
lifecycle testing. It is the UIKit counterpart to
[`SwiftUI/07-Playground`](../../SwiftUI/07-Playground/), and it is literally
[`06-FullReference`](../06-FullReference/) **plus a developer toolbox** —
the complete chat from 06, wrapped in runtime configuration, raw-transport pokes,
live diagnostics, message timestamps, and a filterable event log.

The scene is built **programmatically** — there is no storyboard. `SceneDelegate`
installs a `UINavigationController` wrapping `RootViewController`, which owns the
`ChatSession` plus the dev surfaces (`DevSettings`, `DevDiagnostics`, the log
buffer) across every screen.

## Run it

```bash
open PlaygroundUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## Inherits the full reference

07 reuses 06's complete chat verbatim: the same `RootViewController` screen-state
machine (`private enum Screen { case connect, loading, chat, error }` driving
child-view-controller containment), the same resume-or-start entry flow
(`PolyMessaging.hasResumableSession()`), the same in-place restart
(`session.clearChat()` + `session.client.startNewSession()`), and the same full
feature set — streaming, typing dots, optimistic send/retry, response
suggestions, reconnect/offline banners, and the chat-ended state. None of that is
re-documented here. For the base chat read
[`06-FullReference`](../06-FullReference/) and root
[Build your own UI](../../../README.md#build-your-own-ui).

What follows is **only** what 07 adds.

## The developer toolbox (unique to 07)

Everything below is reachable from the chat screen's overflow menu (`ellipsis.circle`)
and the connect screen's gear (`gearshape`), both installed by
`RootViewController.updateNavItems()`.

### 1. Runtime configuration — `DevSettings`

`DevSettings` is a **public SDK type** (`Sources/PolyMessaging/Public/DevSettings.swift`),
not an example file. `RootViewController` holds one (`private let devSettings = DevSettings()`),
`SettingsViewController` edits its `@Published` knobs (environment, streaming,
greeting, log level, heartbeat/timeout/reconnect, plus
the display toggles), and each connect rebuilds a fresh `Configuration` from it.

> **Under the hood:** `DevSettings` is a UserDefaults-backed runtime
> `Configuration` builder constructed with no arguments — it reads the connector
> token from `PolyMessaging.initialize(...)` and seeds its environment from it.
> `buildConfiguration()` overlays the edited knobs into a `Configuration` that the
> SDK consumes on the **next** session. It bakes in no credentials. Session-creation
> knobs (streaming, greeting, environment) only take effect on
> a fresh session, which is why the sheet offers **Apply & Start New Session**.

```swift
// RootViewController.configureAndStart(forceFresh:)
let config = devSettings.buildConfiguration()
let s = forceFresh
    ? PolyMessaging.start(config)
    : PolyMessaging.chat(config)
diagnostics.attach(to: s.client)
session = s
```

`ConnectViewController` surfaces the resolved environment
(`devSettings.environmentDisplayName()`) and shows a "⚙︎ Custom dev settings
active" badge when `devSettings.hasCustomization` is true.

*See [Reference › Dev tools (QA)](../../../README.md#dev-tools-qa).*

### 2. Streaming toggle

The Connection section of the settings sheet flips
`devSettings.streamingEnabled` (default **on**), which flows into
`devSettings.buildConfiguration()` above and changes how agent replies render.

> **Under the hood:** `Configuration.streamingEnabled` is the single switch.
> When **on** (default), `ChatSession` grows the agent bubble token-by-token as
> chunks arrive (ChatGPT-style). When **off**, the SDK shows the completed
> message in one shot, and the typing indicator stays visible while the agent
> thinks. The chat view code is identical either way; the same `messages` array
> just updates more often.

`streamingEnabled` is a session-creation knob — flipping it takes effect on the
next session, which is why the sheet offers **Apply & Start New Session**.
`devSettings.lastAppliedStreamingEnabled` lets the UI flag that a restart is
needed.

*See [Build your own UI › Streaming](../../../README.md#streaming).*

### 3. The WebSocket buttons (raw transport tap) — `Views/SettingsViewController.swift`, `Views/RootViewController.swift`

The Settings screen has two groups of buttons that poke the live socket directly through `session.client.getConnection()` — the SDK's raw-transport escape hatch.

**Under the hood:** `getConnection()` hands you the *same* live `Connection` the SDK is already running on. Frames sent through it **bypass the managed `send(_:)` path** — no delivery tracking, no retry, no `local_id` correlation, so they emit no `.messagePending` / `.messageConfirmed`. It's for protocol-level pokes, not normal sending.

**"Send frames"** — `RootViewController.rawSend(_:)` → `getConnection().send(OutgoingEvent)`:

| Button | Frame it injects |
|---|---|
| Send HEARTBEAT | `.heartbeat` |
| Send USER_TYPING (started / stopped) | `.userTyping(.started)` / `.userTyping(.stopped)` |
| Send USER_END_SESSION | `.userEndConversation` |
| Send USER_LEFT | `.userLeft` |

**"Disconnect / reconnect"** — `closeWith(code:reason:)` → `getConnection().disconnect(code:reason:)`. The synthesised close code feeds the SDK's classification in `ConnectionService`, so each button exercises a different recovery path:

| Button | Close code | What the SDK does under the hood |
|---|---|---|
| Force reconnect · Simulate network drop | **1006** | transient → reconnect ladder (exponential backoff + jitter), keeps the same `session_id`, replays from the last cursor |
| Simulate idle timeout | **4002** | transient → reconnect (same path as 1006) |
| Simulate server reject | **4001** | invalid session → the SDK refetches a fresh session (new access token + `session_id`), then reconnects |
| Clean disconnect | **1000** | terminal → the reconnect ladder stops; the conversation is over |

> **These are client-side simulations, not backend round-trips.** `disconnect(code:reason:)` tears the socket down and **synthesises a local close event** with the chosen code, which the SDK's *own* `ConnectionService` then classifies. The `40xx` codes are the SDK's internal vocabulary — they are **not** sent to the server as-is (`URLSessionWebSocketTask` coerces the wire close frame to a standard code, ~1000). So these buttons exercise the SDK's reconnect logic locally; the server isn't asked to reject or idle-out. (The **Send frames** buttons above are different — `.userEndConversation` / `.userLeft` send a real `EVENT_TYPE_USER_END_SESSION` to the backend.)

```swift
// RootViewController — inject a wire frame / drive a close code (getConnection escape hatch)
private func rawSend(_ event: OutgoingEvent) {
    guard let client = session?.client else { return }
    Task { @MainActor in
        await client.getConnection().send(event)
        diagnostics.recordOutgoing()
    }
}
private func closeWith(code: Int, reason: String) {
    guard let client = session?.client else { return }
    Task { await client.getConnection().disconnect(code: code, reason: reason) }
}
```

```swift
// RootViewController wires each Settings button to a frame or a close code
vc.onForceReconnect       = { [weak self] in self?.closeWith(code: 1006, reason: "Debug force reconnect") }
vc.onSimulateServerReject = { [weak self] in self?.closeWith(code: 4001, reason: "Debug server-reject simulation") }
vc.onDisconnectClean      = { [weak self] in self?.closeWith(code: 1000, reason: "Debug clean disconnect") }
```

*See [Reference › Advanced: raw transport](../../../README.md#advanced-raw-transport) for the escape hatch, and [How it works](../../../README.md#how-it-works) for the close-code reconnect ladder.*

### 4. Event log

`EventLogger` turns the SDK's typed event stream into `LogEntry` rows, which
`LogsViewController` renders as a count header, a filter field, level-coloured
monospaced rows that expand to show detail, and a copy button.
`RootViewController` filters out noisy optimistic-send and heartbeat traffic
(`shouldLog(_:)`) before appending.

> **Under the hood:** `client.events` is the typed, decoded event stream the SDK
> already runs internally to drive its own behaviour — the playground just taps it
> for logging, introducing no new transport. `EventLogger.makeEntry(event:)` uses
> the SDK's public `debugSummary` / `debugDetail` helpers for human-readable rows.

```swift
// RootViewController.subscribeLifecycle(to:)
for await event in client.events {
    if shouldLog(event) { logs.append(EventLogger.makeEntry(event: event)) }
    // ...
}

private func shouldLog(_ event: MessagingEvent) -> Bool {
    switch event {
    case .messagePending, .messageConfirmed, .messageFailed,
         .heartbeat, .userTyping, .userEndSession, .requestPolyAgentJoin:
        return false
    default:
        return true
    }
}
```

```swift
// EventLogger.swift
static func makeEntry(event: MessagingEvent) -> LogEntry {
    makeEntry(event.debugSummary, detail: event.debugDetail)
}
```

*See [Reference › Dev tools (QA)](../../../README.md#dev-tools-qa).*

### 5. Diagnostics

`DevDiagnostics` is an `@MainActor ObservableObject` of live counters and
protocol state — frames in/out, chunks, heartbeats, reconnects, last sequence,
last-frame age, plus the negotiated `SessionCapabilities`. `RootViewController`
attaches it to the client at session start (`diagnostics.attach(to: s.client)`);
the SDK has no outbound-frame stream, so `rawSend` calls
`diagnostics.recordOutgoing()` manually. `SettingsViewController`'s Diagnostics
section shows the full set, and `DebugStripView` renders the headline numbers live
over the chat when `showDebugStrip` is on.

> **Under the hood:** `DevDiagnostics` subscribes to the SDK's `events`,
> `connectionStatus`, and `sessionState` streams and tallies what it sees — it
> reads `event.envelope?.sequence` to track the reconnect cursor and the
> `SESSION_START` payload's `capabilities` for the negotiated server limits. UIKit
> observes its `@Published` values via Combine (`objectWillChange` + a 1s timer).

```swift
// DevDiagnostics.consume(event:)
if let seq = event.envelope?.sequence, seq > lastSequence { lastSequence = seq }
switch event {
case .sessionStart(_, let payload):
    streamingCapability = payload.capabilities.streaming
    maxMessageSize = payload.capabilities.maxMessageSize
case .agentMessageChunk: chunksIn += 1
case .heartbeat:         heartbeatsIn += 1
default:                 break
}
```

```swift
// DebugStripView.refresh() — the one-line strip over the chat
framesChip.set(icon: "arrow.up.arrow.down",
               text: "\(diagnostics.framesOut)→ ←\(diagnostics.framesIn)",
               color: .white.withAlphaComponent(0.85))
```

*See [Reference › Dev tools (QA)](../../../README.md#dev-tools-qa).*

### 6. Message timestamps

When `showMessageTimestamps` is on, `ChatViewController` interleaves iMessage-style
timestamp rows into the message list. UIKit 07 has **no `TimestampSeparator`
component** (that's SwiftUI-only); instead the chat's diffable data source uses a
`Row` enum (`.timestamp(UUID)` / `.message(UUID)` / `.suggestions(UUID)`), and a
private `TimestampCell` inside `ChatViewController.swift` renders the separator
text. `MessageTimestamp` (a pure-Foundation helper) decides *when* a separator
goes in and *what* it says.

> **Under the hood:** `MessageTimestamp.shouldInsertSeparator(previous:current:)`
> inserts a row whenever the gap to the previous message exceeds ~5 minutes (the
> iMessage grouping threshold); `groupHeader(_:)` formats the label
> (time today, "Yesterday 3:42 PM", weekday this week, month/day this year, else
> month/day/year). The data source maps `.timestamp` rows to a private
> `TimestampCell`.

```swift
// ChatViewController.rows(for:) — builds the diffable rows
for msg in messages {
    if showTimestamps,
       MessageTimestamp.shouldInsertSeparator(previous: previous, current: msg.timestamp) {
        result.append(.timestamp(msg.id))
    }
    result.append(.message(msg.id))
    previous = msg.timestamp
}
```

```swift
// MessageTimestamp.swift
static func shouldInsertSeparator(previous: Date?, current: Date) -> Bool {
    guard let previous else { return true }
    return current.timeIntervalSince(previous) > groupGapSeconds  // 5 * 60
}
```

*See [Build your own UI › Message timestamps](../../../README.md#message-timestamps).*

## What this example is for

- protocol smoke tests against dev / staging / custom environments
- reconnect and close-code experiments
- progressive streaming verification
- checking raw event payloads while keeping `ChatSession` UI behavior visible

## See also

- SwiftUI counterpart: [`Examples/SwiftUI/07-Playground/`](../../SwiftUI/07-Playground/)
- Base chat this builds on: [`06-FullReference`](../06-FullReference/)
- Add the package: root [README → Install](../../../README.md#install)
- Consume `ChatSession` directly: root [README → Build your own UI](../../../README.md#build-your-own-ui)

When you change this example, update the matching snippets in the project
[`README.md`](../../../README.md) **and** the SwiftUI counterpart. See `SKILL.md §12`.
