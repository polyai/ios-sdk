# 07-Playground (UIKit)

The developer toolbox on top of [`06-FullReference`](../06-FullReference/) — the same complete chat (`connect → loading → chat → error`, resume-or-start, in-place restart, delivery tracking, suggestions) wrapped in a QA surface for poking at the protocol: runtime `Configuration` via `DevSettings`, a live streaming toggle, raw-transport `getConnection()` pokes (frames + close-code simulations), a filterable event log, live `DevDiagnostics`, and iMessage-style message timestamps.

- **Interface:** programmatic (no storyboard). `SceneDelegate` wraps a `RootViewController` in a `UINavigationController`.
- **Lifecycle:** `AppDelegate` (`@main`) + `SceneDelegate`.

Use [`06-FullReference`](../06-FullReference/) to learn the chat. Use this one to test the SDK.

## Run it

```bash
open PlaygroundUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your connector token in `AppDelegate.swift` (currently `"YOUR_CONNECTOR_TOKEN"`).

## What this example demonstrates

- Edit a fresh `Configuration` at runtime via `DevSettings` (a public SDK type) and apply it on the next session
- Toggle `Configuration.streamingEnabled` live and verify token-by-token vs complete-message rendering
- Poke the live WebSocket via `client.getConnection().send(_:)` (raw frames) and `.disconnect(code:reason:)` (close-code simulations)
- Tap `client.events` for a filterable, copyable log of every typed event
- Subscribe to `client.events` / `client.connectionStatus` / `client.sessionState` for live diagnostic counters
- Render iMessage-style timestamp rows using each `ChatMessage.timestamp`

## How it works

Each subsection leads with **the SDK call(s)** (the actual API), then shows **how it's wired into a view controller**.

### Runtime configuration via `DevSettings` — `Views/SettingsViewController.swift`

`DevSettings` is a **public SDK type** (`Sources/PolyMessaging/Public/DevSettings.swift`) — an `@MainActor open class DevSettings: ObservableObject` backed by `UserDefaults`. Construct it with no arguments after `initialize(_:)`; it reads the connector token from `PolyMessaging.currentConfig` and seeds its environment from there, so it bakes in no credentials. Edit the published knobs live; `buildConfiguration()` folds them into a `Configuration` the SDK consumes on the **next** session.

The SDK calls:

```swift
DevSettings()                       // a UserDefaults-backed bag of @Published runtime knobs
settings.environmentKind            // .production / .staging / .dev / .cluster / .custom
settings.streamingEnabled           // session-creation knob — flip resets text-by-token rendering
settings.heartbeatIntervalSeconds   // 0 = "use the SDK default"
settings.sessionTimeoutSeconds      // 0 = "use the SDK default"
settings.maxReconnectAttempts       // 0 = "use the SDK default"

settings.buildConfiguration()       // → Configuration consumed on the next session
PolyMessaging.chat(_: Configuration)
PolyMessaging.start(_: Configuration)
```

In a view controller (root holds the single `DevSettings` across every screen):

```swift
final class RootViewController: UIViewController {
    private let devSettings = DevSettings()
    private let diagnostics = DevDiagnostics()
    private var logs: [LogEntry] = []
    private var session: ChatSession?

    private func configureAndStart(forceFresh: Bool) {
        // ...short-circuit if a live session already exists...

        let config = devSettings.buildConfiguration()
        let s = forceFresh
            ? PolyMessaging.start(config)
            : PolyMessaging.chat(config)
        diagnostics.attach(to: s.client)
        session = s
        showLoading()
        subscribeLifecycle(to: s.client)
    }
}
```

`SettingsViewController` edits the `@Published` knobs (UIKit reads them via Combine + `objectWillChange` + a 1s refresh timer for the live counters); `ConnectViewController` surfaces `devSettings.environmentDisplayName()` and a "Custom dev settings active" badge when `devSettings.hasCustomization` is true.

**Under the hood:** session-creation knobs (environment, streaming, greeting) take effect only on a fresh session — that's why the sheet shows "Apply & Start New Session". `lastAppliedStreamingEnabled` on `DevSettings` lets the UI flag when the running session is out of sync with the current knobs.

*See [Integration guide › Configuration](../../../README.md#configuration).*

### Streaming toggle — `Views/SettingsViewController.swift`

The Connection section of the sheet flips `devSettings.streamingEnabled` (default **on**), which flows into the next `buildConfiguration()`:

The SDK signal:

```swift
Configuration.streamingEnabled   // the single switch for token-by-token vs complete-message
settings.streamingEnabled        // the live DevSettings knob
settings.lastAppliedStreamingEnabled   // the value the running session was started with
```

In a view controller (a `UISwitch` inside a settings cell):

```swift
let toggle = UISwitch()
toggle.isOn = settings.streamingEnabled
toggle.addAction(UIAction { [weak settings] _ in
    settings?.streamingEnabled = toggle.isOn
}, for: .valueChanged)

// In the section footer, show a "Restart to apply" hint when the running
// session was started with a different value:
if hasAnySession && settings.streamingEnabled != settings.lastAppliedStreamingEnabled {
    footerLabel.text = "Restart the session to apply"
}
```

**Under the hood:** when `streamingEnabled: true` (default), `ChatSession` extends the last `.agent` message's `text` on every chunk and re-publishes `$messages` — the diffable data source reconfigures the cell with the longer text. When `false`, the SDK shows the assembled message in one shot and keeps `$isAgentTyping` true while the agent thinks. The chat code is identical either way; the same `messages` array just updates differently.

*See [Integration guide › Streaming](../../../README.md#streaming).*

### Raw transport: send frames — `Views/SettingsViewController.swift`, `Views/RootViewController.swift`

`getConnection()` hands you the *same* live `Connection` the SDK is already running on. Frames sent through it **bypass the managed `send(_:)` path** — no delivery tracking, no retry, no `local_id` correlation, no `.messagePending` / `.messageConfirmed`. It's for protocol-level pokes, not normal sending.

The SDK call:

```swift
session.client.getConnection().send(_: OutgoingEvent)   // raw frame injection
```

Buttons in the Settings sheet inject these frames:

| Button | Frame |
|---|---|
| Send HEARTBEAT | `.heartbeat` |
| Send USER_TYPING (started / stopped) | `.userTyping(.started)` / `.userTyping(.stopped)` |
| Send USER_END_SESSION | `.userEndConversation` |
| Send USER_LEFT | `.userLeft` |

In a view controller (root wires each settings button to its raw frame):

```swift
private func presentSettings() {
    let vc = SettingsViewController(/* ... */)
    vc.onSendHeartbeat       = { [weak self] in self?.rawSend(.heartbeat) }
    vc.onSendTypingStart     = { [weak self] in self?.rawSend(.userTyping(.started)) }
    vc.onSendTypingStop      = { [weak self] in self?.rawSend(.userTyping(.stopped)) }
    vc.onSendUserEndSession  = { [weak self] in self?.rawSend(.userEndConversation) }
    vc.onSendUserLeft        = { [weak self] in self?.rawSend(.userLeft) }
    // ...close-code buttons below...
    present(UINavigationController(rootViewController: vc), animated: true)
}

private func rawSend(_ event: OutgoingEvent) {
    guard let client = session?.client else { return }
    Task { @MainActor in
        await client.getConnection().send(event)
        diagnostics.recordOutgoing()   // SDK has no outbound-frame stream — count manually
    }
}
```

**Under the hood:** `.userEndConversation` / `.userLeft` are real frames the backend processes (a server-side `EVENT_TYPE_USER_END_SESSION`); `.heartbeat` and `.userTyping` are protocol bookkeeping. Because the managed `send(_:)` path isn't involved, the SDK won't surface these as messages or delivery events — they're invisible to `session.messages`.

*See [Integration guide › Raw transport](../../../README.md#raw-transport).*

### Raw transport: close-code simulations — `Views/SettingsViewController.swift`, `Views/RootViewController.swift`

`disconnect(code:reason:)` tears the socket down and **synthesises a local close event** with your chosen code, which the SDK's own `ConnectionService` then classifies. Each close code exercises a different recovery path:

The SDK call:

```swift
session.client.getConnection().disconnect(code: Int, reason: String)
```

| Button | Close code | What the SDK does |
|---|---|---|
| Force reconnect · Simulate network drop | **1006** | transient → reconnect ladder (exponential backoff + jitter), keeps the same `session_id`, replays from the last cursor |
| Simulate idle timeout | **4002** | transient → reconnect (same path as 1006) |
| Simulate server reject | **4001** | invalid session → SDK refetches a fresh session (new access token + `session_id`), then reconnects |
| Clean disconnect | **1000** | terminal → reconnect ladder stops; the conversation is over |

In a view controller:

```swift
private func closeWith(code: Int, reason: String) {
    guard let client = session?.client else { return }
    Task { await client.getConnection().disconnect(code: code, reason: reason) }
}

// Wires in presentSettings():
vc.onForceReconnect       = { [weak self] in self?.closeWith(code: 1006, reason: "Debug force reconnect") }
vc.onSimulateDrop         = { [weak self] in self?.closeWith(code: 1006, reason: "Debug simulated drop") }
vc.onSimulateServerReject = { [weak self] in self?.closeWith(code: 4001, reason: "Debug server-reject simulation") }
vc.onSimulateIdleTimeout  = { [weak self] in self?.closeWith(code: 4002, reason: "Debug idle-timeout simulation") }
vc.onDisconnectClean      = { [weak self] in self?.closeWith(code: 1000, reason: "Debug clean disconnect") }
```

**Under the hood:** these are **client-side simulations**, not backend round-trips. The `40xx` codes are the SDK's internal vocabulary — they're **not** sent to the server as-is (`URLSessionWebSocketTask` coerces the wire close frame to a standard code, ~1000). The buttons exercise the SDK's own reconnect classification locally; the server isn't asked to reject or idle-out.

*See [Integration guide › Raw transport](../../../README.md#raw-transport).*

### Event log — `Helpers/EventLogger.swift`, `Views/LogsViewController.swift`

Tap `client.events` for a filterable, copyable record of every typed event. `EventLogger` turns each `MessagingEvent` into a `LogEntry` using the SDK's own `debugSummary` / `debugDetail`:

The SDK signal:

```swift
session.client.events     // AsyncStream<MessagingEvent> — the typed, decoded stream
event.debugSummary        // public: one-line human summary
event.debugDetail         // public: optional multi-line detail
```

In a view controller (root subscribes once, in `subscribeLifecycle(to:)`):

```swift
lifecycleTasks.append(Task { @MainActor [weak self] in
    for await event in client.events {
        guard let self else { return }
        if self.shouldLog(event) {
            self.logs.append(EventLogger.makeEntry(event: event))
        }
        // ...also drive the loading → chat transitions...
    }
})

private func shouldLog(_ event: MessagingEvent) -> Bool {
    switch event {
    case .messagePending, .messageConfirmed, .messageFailed,
         .heartbeat, .userTyping, .userEndSession, .requestPolyAgentJoin:
        return false   // drop high-frequency / optimistic noise
    default:
        return true
    }
}
```

```swift
// EventLogger.swift — SDK event → log row
static func makeEntry(event: MessagingEvent) -> LogEntry {
    makeEntry(event.debugSummary, detail: event.debugDetail)
}
```

`LogsViewController` renders rows with a count header, filter field, level-coloured monospaced labels that expand to show detail, and a copy button.

**Under the hood:** `client.events` is the same stream the SDK uses internally to drive its own behaviour — tapping it adds no new transport. `debugSummary` / `debugDetail` are public helpers that format envelope + payload in a stable way, so log rows survive SDK upgrades.

### Live diagnostics — `Helpers/DevDiagnostics.swift`, `Components/DebugStripView.swift`

`DevDiagnostics` is an `@MainActor ObservableObject` that subscribes to the same three lifecycle streams and tallies counters — session id, ready state, reconnect cursor (`lastSequence`), frames in/out, streaming chunks, heartbeats, reconnects, last-inbound time, and the negotiated `SessionCapabilities`:

The SDK signals:

```swift
client.events                     // tally framesIn, chunksIn, heartbeatsIn, lastSequence
client.connectionStatus           // tally reconnects, current state
client.sessionState               // capture sessionId / ready state
event.envelope?.sequence          // reconnect cursor
.sessionStart(_, payload).capabilities   // server-negotiated SessionCapabilities
```

In a view controller:

```swift
// RootViewController.configureAndStart — attach after the client is built
diagnostics.attach(to: s.client)
```

```swift
// DevDiagnostics.swift — subscribe once, tally from the SDK streams
func attach(to client: PolyMessagingClient) {
    reset()
    eventTask = Task { [weak self] in
        for await event in client.events { await self?.consume(event) }
    }
    // ...also connectionStatus + sessionState...
}

private func consume(event: MessagingEvent) {
    framesIn += 1
    lastInboundAt = Date()
    if let seq = event.envelope?.sequence, seq > lastSequence { lastSequence = seq }
    switch event {
    case .sessionStart(_, let payload):
        streamingCapability = payload.capabilities.streaming
        maxMessageSize = payload.capabilities.maxMessageSize
    case .agentMessageChunk: chunksIn += 1
    case .heartbeat:         heartbeatsIn += 1
    default:                 break
    }
}
```

```swift
// DebugStripView.refresh() — the one-line strip over the chat
framesChip.set(icon: "arrow.up.arrow.down",
               text: "\(diagnostics.framesOut)→ ←\(diagnostics.framesIn)",
               color: .white.withAlphaComponent(0.85))
```

**Under the hood:** the SDK has no outbound-frame stream, so `recordOutgoing()` is called by the raw-transport tap to count frames out — every other counter is read off the SDK's published streams. UIKit observes the `@Published` values via Combine (`objectWillChange` + a 1s timer keeps the visible counters fresh even between events).

### Message timestamps — `Helpers/MessageTimestamp.swift`, `Views/ChatViewController.swift`

Every `ChatMessage` already carries a `timestamp`. When `DevSettings.showMessageTimestamps` is on, the chat's diffable data source interleaves iMessage-style timestamp rows wherever the gap between two consecutive messages exceeds ~5 minutes. UIKit 07 has no `TimestampSeparator` component (that's SwiftUI-only); instead a `.timestamp(UUID)` case is added to the `Row` enum and a private `TimestampCell` renders the label:

The SDK signal:

```swift
ChatMessage.timestamp   // Date set when the message was sent / received
```

In a view controller:

```swift
private enum Row: Hashable {
    case timestamp(UUID)
    case message(UUID)
    case suggestions(UUID)
}

private func rows(for messages: [ChatMessage]) -> [Row] {
    var result: [Row] = []
    var previous: Date? = nil
    for msg in messages {
        if showTimestamps,
           MessageTimestamp.shouldInsertSeparator(previous: previous, current: msg.timestamp) {
            result.append(.timestamp(msg.id))
        }
        result.append(.message(msg.id))
        previous = msg.timestamp
    }
    return result
}
```

```swift
// MessageTimestamp.swift — the grouping rule (true also for the first message)
static func shouldInsertSeparator(previous: Date?, current: Date) -> Bool {
    guard let previous else { return true }
    return current.timeIntervalSince(previous) > groupGapSeconds   // ~5 * 60
}
```

**Under the hood:** the timestamp is already on every `ChatMessage` the SDK publishes — there's no extra subscription. `MessageTimestamp` owns the grouping rule and the locale-aware formatters (time today, "Yesterday 3:42 PM", weekday this week, month/day this year, else full date).

## What this example is for

- protocol smoke tests against dev / staging / cluster / custom environments
- reconnect and close-code experiments (1006 / 4001 / 4002 / 1000)
- progressive-streaming verification with the live toggle
- inspecting raw event payloads while keeping `ChatSession`'s UI behaviour visible

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/07-Playground/`](../../SwiftUI/07-Playground/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
