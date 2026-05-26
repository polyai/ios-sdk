# 07-Playground

The most extensive example in the ladder: **[`06-FullReference`](../06-FullReference/)
plus a developer toolbox.** Same complete chat app — every connect / loading /
chat / error screen and every rendering component is inherited from 06 — wrapped
in a QA surface for poking at the protocol: runtime `Configuration` knobs, a raw
transport tap, live diagnostics, a filterable event log, progressive-streaming
verification, and message timestamps.

Use 06 to learn the chat. Use 07 to test the SDK.

## Run it

```bash
open PlaygroundSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## Inherits the full reference

07 reuses 06's complete chat verbatim — the same `enum AppScreen` screen-state
machine (`connect → loading → chat → error`), resume-or-start via
`PolyMessaging.hasResumableSession()`, in-place `startNewSession()` + `clearChat()`,
recoverable error routing, delayed "Sending…" labels, retry, and streaming-aware
scroll — driven by the same `client.events` / `client.connectionStatus` /
`client.sessionState` streams. It also draws every message with the exact same
components promoted into [`Examples/Components/`](../../Components/).

None of that is re-documented here. For the base chat see
[`06-FullReference`](../06-FullReference/), and for the per-feature build-your-own-UI
recipes see the root [Build your own UI](../../../README.md#build-your-own-ui).
This README deep-dives only what 07 *adds*.

## The developer toolbox (unique to 07)

Everything below is real code from this app, against public SDK types only.

### 1. Runtime config via `DevSettings` — `Views/SettingsSheet.swift`

**Under the hood:** `DevSettings` is a **public SDK type**
(`Sources/PolyMessaging/Public/DevSettings.swift`, a `@MainActor open class
DevSettings: ObservableObject`) — not an example file. Construct it with no
arguments after `initialize(_:)`: it reads the connector token from
`PolyMessaging.currentConfig` and seeds its environment from it (the `X-Host` is
derived from the selected environment), so it bakes in no credentials. It's a
UserDefaults-backed bag of runtime knobs — environment (production / staging / dev /
cluster / custom URLs), `streamingEnabled`, `greetingMessage`, and the timing knobs
`heartbeatIntervalSeconds` / `sessionTimeoutSeconds` / `maxReconnectAttempts`
(0 = "use the SDK default").
`SettingsSheet` edits those `@Published` knobs live; `buildConfiguration()` folds
them into a `Configuration` the SDK consumes **on the next session** (existing
sessions don't change — the sheet shows an "Apply & Start New Session" banner for
exactly that reason).

```swift
// SettingsSheet.swift — each knob is a two-way binding onto the SDK object
@ObservedObject var settings: DevSettings

Picker("Target", selection: Binding(
    get: { settings.environmentKind },
    set: { settings.environmentKind = $0 }
)) {
    ForEach(DevSettings.EnvironmentKind.allCases) { kind in
        Text(kind.displayName).tag(kind)
    }
}
```

```swift
// ContentView.swift — buildConfiguration() → applied on the next session
let config = devSettings.buildConfiguration()
let s = forceFresh
    ? PolyMessaging.start(config)
    : PolyMessaging.chat(config)
diagnostics.attach(to: s.client)
```

*See [Reference › Dev tools (QA)](../../../README.md#dev-tools-qa).*

### 2. Streaming toggle — `Views/SettingsSheet.swift`

**Under the hood:** `Configuration.streamingEnabled` is the single switch for streaming.
When `true` (default) `ChatSession` grows the agent bubble token-by-token as chunks land;
when `false`, the SDK shows the assembled message in one shot (and keeps the typing
indicator alive while the agent thinks). Flip the toggle in the Settings sheet — it lives
on the `DevSettings.streamingEnabled` knob, which flows into the next `buildConfiguration()`.

```swift
// SettingsSheet.swift — Connection section already has this toggle:
Toggle("Streaming (server chunks)", isOn: Binding(
    get: { settings.streamingEnabled },
    set: { settings.streamingEnabled = $0 }
))
```

A changed `streamingEnabled` applies on the next session — pause back to the
connect screen and resume, or tap "New conversation". `lastAppliedStreamingEnabled`
on `DevSettings` lets the UI flag that a restart is needed.

*See [Build your own UI › Streaming](../../../README.md#streaming).*

### 3. The WebSocket buttons (raw transport tap) — `Views/SettingsSheet.swift`, `Views/ContentView.swift`

The Settings sheet has two groups of buttons that poke the live socket directly through `session.client.getConnection()` — the SDK's raw-transport escape hatch.

**Under the hood:** `getConnection()` hands you the *same* live `Connection` the SDK is already running on. Frames sent through it **bypass the managed `send(_:)` path** — no delivery tracking, no retry, no `local_id` correlation, so they emit no `.messagePending` / `.messageConfirmed`. It's for protocol-level pokes, not normal sending.

**"Send frames"** — `rawSend(_:)` → `getConnection().send(OutgoingEvent)`:

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
// ContentView.swift — inject a wire frame / drive a close code, bypassing the managed path
private func rawSend(_ event: OutgoingEvent) {
    guard let c = session?.client else { return }
    Task { await c.getConnection().send(event); diagnostics.recordOutgoing() }
}
private func closeWith(code: Int, reason: String) {
    guard let c = session?.client else { return }
    Task { await c.getConnection().disconnect(code: code, reason: reason) }
}
```

```swift
// SettingsSheet wires each button; ContentView maps it to a frame or a close code
onSendHeartbeat:        { rawSend(.heartbeat) },
onSendUserLeft:         { rawSend(.userLeft) },
onForceReconnect:       { forceReconnect() },                                  // disconnect(1006)
onSimulateServerReject: { closeWith(code: 4001, reason: "Debug server-reject simulation") },
onDisconnectClean:      { closeWith(code: 1000, reason: "Debug clean disconnect") },
```

*See [Reference › Advanced: raw transport](../../../README.md#advanced-raw-transport) for the escape hatch, and [How it works](../../../README.md#how-it-works) for the close-code reconnect ladder.*

### 4. Event log — `Helpers/EventLogger.swift`, `Views/LogsSheet.swift`

**Under the hood:** `client.events` is the typed, decoded event stream the SDK
already runs internally to drive its own behaviour — the playground just taps it
for logging, adding no new transport. `EventLogger` turns each `MessagingEvent`
into a `LogEntry` (a `summary` + optional `detail`, from the SDK's own
`event.debugSummary` / `event.debugDetail`); `LogsSheet` renders, filters, and
copies them. A `shouldLog(_:)` predicate drops the noisy high-frequency events
(heartbeats, typing, and the optimistic `messagePending` / `messageConfirmed` /
`messageFailed`) so the log stays readable.

```swift
// EventLogger.swift — SDK event → log row
static func makeEntry(event: MessagingEvent) -> LogEntry {
    makeEntry(event.debugSummary, detail: event.debugDetail)
}
```

```swift
// ContentView.swift — tap client.events, skipping the noisy ones
for await event in client.events {
    if shouldLog(event) {
        logs.append(EventLogger.makeEntry(event: event))
    }
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

*See [Reference › Dev tools (QA)](../../../README.md#dev-tools-qa).*

### 5. Diagnostics — `Helpers/DevDiagnostics.swift`, `Components/DebugStrip.swift`

**Under the hood:** `DevDiagnostics` is an `ObservableObject` that subscribes to
the same three SDK streams (`client.events`, `client.connectionStatus`,
`client.sessionState`) and tallies live counters — session id, ready state, the
reconnect cursor (`lastSequence`), frames in/out, streaming chunks, heartbeats,
reconnects, last-inbound time, plus the server `SessionCapabilities` reported at
`.sessionStart`. The SDK has no outbound-frame stream, so `recordOutgoing()` is
called by the raw-transport tap to count frames out. `DebugStrip` mirrors the most
useful counters into a one-line always-on chip over the chat (gated by
`DevSettings.showDebugStrip`); the full read-out lives in the settings sheet's
Diagnostics section.

```swift
// DevDiagnostics.swift — subscribe once, tally from the SDK streams
func attach(to client: PolyMessagingClient) {
    reset()
    let events = client.events
    eventTask = Task { [weak self] in
        for await event in events { await self?.consume(event) }
    }
    // ...also connectionStatus and sessionState
}

private func consume(event: MessagingEvent) {
    framesIn += 1
    lastInboundAt = Date()
    if let seq = event.envelope?.sequence, seq > lastSequence { lastSequence = seq }
    switch event {
    case .sessionStart(_, let payload):
        streamingCapability = payload.capabilities.streaming
    case .agentMessageChunk: chunksIn += 1
    case .heartbeat:         heartbeatsIn += 1
    default: break
    }
}
```

```swift
// DebugStrip.swift — live one-line overlay
chip(systemImage: "number", text: "seq \(diagnostics.lastSequence)")
chip(systemImage: "arrow.up.arrow.down", text: "\(diagnostics.framesOut)→ ←\(diagnostics.framesIn)")
```

*See [Reference › Dev tools (QA)](../../../README.md#dev-tools-qa).*

### 6. Message timestamps — `Helpers/MessageTimestamp.swift`, `Components/TimestampSeparator.swift`

**Under the hood:** every `ChatMessage` already carries a `timestamp`. When
`DevSettings.showMessageTimestamps` is on, `ChatView` walks the list and inserts a
centered separator row (iMessage style) wherever the gap between two consecutive
messages exceeds `MessageTimestamp.groupGapSeconds` (~5 min), plus above the very
first message. `MessageTimestamp` owns the grouping rule and the cached
locale-aware formatters; `TimestampSeparator` draws the pill.

```swift
// ChatView.swift — insert a separator when the time gap is large enough
if showTimestamps,
   MessageTimestamp.shouldInsertSeparator(
       previous: index > 0 ? messages[index - 1].timestamp : nil,
       current: message.timestamp
   ) {
    TimestampSeparator(date: message.timestamp)
}
```

```swift
// MessageTimestamp.swift — the grouping rule (true also for the first message)
static func shouldInsertSeparator(previous: Date?, current: Date) -> Bool {
    guard let previous else { return true }
    return current.timeIntervalSince(previous) > groupGapSeconds
}
```

*See [Build your own UI › Message timestamps](../../../README.md#message-timestamps).*

## What this example is for

- protocol smoke tests against dev / staging / cluster / custom environments
- reconnect and close-code experiments (1006 / 4001 / 4002 / 1000)
- progressive-streaming verification
- inspecting raw event payloads while keeping `ChatSession`'s UI behaviour visible

---

**Cross-framework counterpart:** the UIKit twin of this app is
[`Examples/UIKit/07-Playground/`](../../UIKit/07-Playground/) — same toolbox, same
connector-token wiring; only the UI binding differs.

Add the package via root [README → Install](../../../README.md#install), then
follow root [README → Build your own UI](../../../README.md#build-your-own-ui) to
drive these components from `ChatSession`.

When you change this example, update the matching snippets in the project
[`README.md`](../../../README.md) **and** the UIKit counterpart at
[`Examples/UIKit/07-Playground/`](../../UIKit/07-Playground/). See `SKILL.md §12`.
