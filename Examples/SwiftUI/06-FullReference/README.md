# 06-FullReference (SwiftUI)

The complete reference app on top of [`05-Handoff`](../05-Handoff/) — every feature from 02–05 folded into one production-shaped flow (`connect → loading → chat → error`), plus the lifecycle plumbing the lighter levels skip: resume-or-start, in-place start-new, recoverable error routing, delayed "Sending…" labels, and streaming-aware scroll restoration.

## Run it

```bash
open FullReferenceSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your connector token in `FullReferenceApp.swift` (currently `"YOUR_CONNECTOR_TOKEN"`).

## What this example demonstrates

- A screen-state machine (`enum AppScreen { case connect, loading, chat, error }`) that's a pure function of SDK lifecycle streams
- Resume-or-start picker driven by `PolyMessaging.hasResumableSession()` + the choice between `chat()` and `start()`
- Loading → chat / error transitions driven by `client.events`, `client.connectionStatus`, and `client.sessionState`
- A recoverable error screen with a "Go Back" route to connect (not a latched terminal flag)
- In-place start-new via `session.clearChat()` + `session.client.startNewSession()` — no screen change
- Destructive `session.end()` followed by a return to connect
- Delayed "Sending…" label (~500ms debounce) so fast confirmations never flash it
- Retry that calls `session.removeMessage(draftId:)` before re-sending, so failed bubbles never linger
- Streaming-aware scroll: re-anchor on text-length growth, not just `messages.count`

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them as one concrete multi-screen app.

## How it works

Each subsection leads with **the SDK call** (one or a few lines — the actual API), then shows **how it's wired into a view**.

### Screen-state machine — `Views/ContentView.swift`

Model the whole app as one explicit enum and swap the screen on it. Every transition is driven by an SDK signal:

The SDK calls:

```swift
PolyMessaging.initialize(_:)        // once, in FullReferenceApp.init — connection details
PolyMessaging.hasResumableSession() // side-effect-free probe of the on-disk session store
PolyMessaging.chat()                // resume the persisted session if valid, else start fresh
PolyMessaging.start()               // always discard any stored session and start fresh
```

In a view:

```swift
enum AppScreen: Equatable {
    case connect
    case loading
    case chat
    case error(message: String)

    var isError: Bool { if case .error = self { true } else { false } }
}

struct ContentView: View {
    @State private var screen: AppScreen = .connect
    @State private var session: ChatSession?
    @State private var wasResumed = false
    @State private var showEndConfirm = false

    var body: some View {
        NavigationView {
            currentScreen
                .navigationTitle("PolyMessaging")
                .toolbar { toolbarItems }
                .alert("End Conversation", isPresented: $showEndConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("End Conversation", role: .destructive) { endConversation() }
                } message: {
                    Text("This will permanently end the current conversation. You won't be able to resume it.")
                }
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch screen {
        case .connect:
            ConnectView(
                hasActiveSession: session != nil,
                canResume: PolyMessaging.hasResumableSession(),
                onResume:   { configureAndStart(forceFresh: false) },
                onStartNew: { configureAndStart(forceFresh: true) }
            )
        case .loading:
            LoadingView()
        case .chat:
            if let session {
                ChatScreen(session: session, /* ...bindings + callbacks... */)
            }
        case .error(let msg):
            ErrorScreen(message: msg, onBack: { screen = .connect })
        }
    }
}
```

**Under the hood:** `initialize` stashes the connector token and environment process-wide — no network happens yet. The no-arg facade calls (`chat()`, `start()`, `hasResumableSession()`) reuse that config from any view. `chat()` resumes the persisted session when it's still valid (within the session timeout) and otherwise creates a fresh one; `start()` always discards. `hasResumableSession()` is a pure on-disk probe with no side effects, so it's safe to call on every render of the connect screen.

*See [Integration guide › Quick start](../../../README.md#quick-start) and [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### Loading → chat / error via lifecycle streams — `Views/ContentView.swift`

Don't poll for "is it connected yet" — subscribe to the three lifecycle streams on `client` and let them drive the transitions:

The SDK signals:

```swift
client.events            // AsyncStream<MessagingEvent> — .sessionStart, .disconnected, etc.

client.connectionStatus  // AsyncStream<ConnectionStatus> — .connecting / .connected / .reconnecting / .failed

client.sessionState      // AsyncStream<SessionState> — .isReady flips true when the session can send
```

In a view:

```swift
private func configureAndStart(forceFresh: Bool) {
    // ...short-circuit if a live session already exists...

    let s = forceFresh ? PolyMessaging.start() : PolyMessaging.chat()
    session = s
    wasResumed = false
    screen = .loading

    let client = s.client
    Task {
        for await event in client.events {
            if case .sessionStart = event, screen == .loading { screen = .chat }
            if case .disconnected(let err) = event, let err, screen == .loading {
                screen = .error(message: "Couldn't connect.\n\(err)")
            }
        }
    }
    Task {
        for await status in client.connectionStatus {
            if case .failed(let reason) = status, screen == .loading {
                let message = reason.map { String(describing: $0) } ?? "Unknown failure"
                screen = .error(message: "Connection failed.\n\(message)")
            }
        }
    }
    Task {
        for await state in client.sessionState {
            if state.status == .restored { wasResumed = true }
            if state.isReady, screen == .loading || screen.isError { screen = .chat }
            if state.isError, screen == .loading {
                screen = .error(message: state.errorMessage ?? "Couldn't start the session.")
            }
        }
    }
}
```

**Under the hood:** loading → chat is gated on `state.isReady` (or a `.sessionStart` event) and only fires *while still loading*, so a mid-chat reconnect never throws the user back to the loading screen. Errors are routed to `.error(message:)` only while loading, for the same reason — a transient blip after the chat is up just flips `connection` and recovers itself. `state.status == .restored` is how you know it's a warm resume (used to flash the "Resumed previous conversation" banner).

*See [Integration guide › Connection & reconnect](../../../README.md#connection--reconnect).*

### Recoverable error screen — `Views/ErrorScreen.swift`

06's terminal state is not a latched failure flag — it's just `AppScreen.error(message:)` set by the lifecycle subscriptions above. "Go Back" routes to `.connect`, where the user can resume or start fresh:

The SDK signal that fed it:

```swift
session.client.sessionState   // .isError on session-creation failure
// (and .failed on connectionStatus, .disconnected(error) on events)
```

In a view:

```swift
struct ErrorScreen: View {
    let message: String
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Something went wrong").font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button(action: onBack) { Text("Go Back") }
                .buttonStyle(.borderedProminent)
        }
    }
}
```

The error subtitles use `String(describing:)` on `PolyError` rather than `.localizedDescription`, because `PolyError` doesn't conform to `LocalizedError` (the default would just say "The operation couldn't be completed").

**Under the hood:** routing errors only while `.loading` means the error screen is recoverable by design — you can go back to connect and retry. If you want a non-recoverable terminal screen instead (the `04-Resilience` pattern), bind to `session.failureReason` directly.

*See [Integration guide › Terminal errors](../../../README.md#terminal-errors).*

### Resume-or-start picker — `Views/ConnectView.swift`

The connect screen picks button labels off `hasResumableSession()`:

The SDK call:

```swift
PolyMessaging.hasResumableSession()   // true if a stored session is within the timeout
```

In a view:

```swift
struct ConnectView: View {
    let hasActiveSession: Bool
    let canResume: Bool
    let onResume: () -> Void
    let onStartNew: () -> Void

    var body: some View {
        // ...header...

        let primaryShowsResume = hasActiveSession || canResume

        Button { onResume() } label: {
            HStack(spacing: 8) {
                Image(systemName: primaryShowsResume
                      ? "arrow.uturn.forward.circle.fill"
                      : "bolt.fill")
                Text(primaryShowsResume ? "Resume Chat" : "Start Chat")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)

        if primaryShowsResume {
            Button { onStartNew() } label: { Text("Start New Chat") }
                .buttonStyle(.bordered)
        }
    }
}
```

**Under the hood:** `hasResumableSession()` is a side-effect-free on-disk check (no network), so it's safe to call every render — keeping the buttons honest as the user moves between connect / chat / connect.

*See [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### In-place start-new — `Views/ContentView.swift`

When the chat ends, the chat-ended footer offers a new conversation without bouncing through the connect screen:

The SDK calls:

```swift
session.clearChat()                  // wipe the local transcript immediately
session.client.startNewSession()     // ends the current server session, starts a fresh one on the SAME client
```

In a view:

```swift
private func startNewConversationInPlace() {
    guard let s = session else { return }
    s.clearChat()
    Task { try? await s.client.startNewSession() }
}
```

**Under the hood:** `clearChat()` and `startNewSession()` work on the same client — so the lifecycle subscriptions (tied to that client) don't need re-arming. `ChatSession` detects the new session id and resets its latched flags, so the screen converges on a clean conversation without leaving `.chat`.

*See [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### End → back to connect — `Views/ContentView.swift`

`end()` tears down the server-side session for good (it can't be resumed afterwards). A destructive confirmation guards it, then we drop the local `session` and route back to `.connect`:

The SDK call:

```swift
session.end()   // permanent; the conversation cannot be resumed after this
```

In a view:

```swift
private func endConversation() {
    let pending = session
    Task {
        try? await pending?.end()
        session = nil
        wasResumed = false
        screen = .connect
    }
}
```

**Under the hood:** awaiting `end()` before clearing the local `session` ensures the server has acknowledged the teardown before the connect screen re-probes `hasResumableSession()` — otherwise you can get a phantom "Resume" button for a session that's already dead.

*See [Integration guide › Session lifecycle](../../../README.md#session-lifecycle).*

### Delayed "Sending…" label — `Views/ContentView.swift` (`ChatScreen`)

The SDK already tracks real delivery (`.pending` → `.sent`); the ~500ms delay is purely app-side polish on *showing* the label, so fast confirmations never flash it:

The SDK signal:

```swift
ChatMessage.delivery   // .pending / .sent / .failed (.pending on optimistic send)
```

In a view:

```swift
@State private var sendingLabels: Set<UUID> = []
@State private var trackedPending: Set<UUID> = []

private func syncSendingLabels(_ messages: [ChatMessage]) {
    for case .user(let u) in messages where u.delivery == .pending && !trackedPending.contains(u.id) {
        trackedPending.insert(u.id)
        let id = u.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Only show the label if the draft is STILL pending after 500ms.
            guard case .user(let current) = session.messages.first(where: { $0.id == id }),
                  current.delivery == .pending else { return }
            sendingLabels.insert(id)
        }
    }
    // Drop ids that left .pending — keeps the sets in sync with reality.
    let stillPending: Set<UUID> = Set(messages.compactMap {
        if case .user(let u) = $0, u.delivery == .pending { return u.id }
        return nil
    })
    sendingLabels.formIntersection(stillPending)
    trackedPending.formIntersection(stillPending)
}
```

**Under the hood:** this only gates *display* — the SDK still reports `.pending` immediately and `.sent` the moment the server confirms. The bubble is in `messages` from the first frame either way; the label is the only thing this code controls.

*See [Integration guide › Delivery state & retry](../../../README.md#delivery--read-state).*

### Retry removes the failed draft, then re-sends — `Views/ContentView.swift`

A failed optimistic message stays in `messages` as a real draft keyed by its `draftId`. Retry drops the stale bubble first, then re-sends the text:

The SDK calls:

```swift
session.removeMessage(draftId:)   // drop the failed optimistic draft from messages
session.send(_:)                  // re-send as a fresh draft (new id)
```

In a view:

```swift
onRetry: { text, draftId in
    if let draftId { session.removeMessage(draftId: draftId) }
    onSend(text)
}
```

**Under the hood:** without `removeMessage`, retrying would leave a "Failed" bubble next to the new attempt — `send()` always creates a fresh draft id rather than mutating the old one. Dropping the failed draft first is what keeps the transcript clean.

*See [Integration guide › Delivery state & retry](../../../README.md#delivery--read-state).*

### Streaming-aware scroll restoration — `Views/ChatView.swift`

Streaming agent replies grow the *text* of an existing bubble without changing `messages.count`, so a naive "scroll on new message" misses them. Keep a stable anchor and re-scroll on every signal that can change content height:

The SDK signals:

```swift
session.messages.count                 // new bubble arrived
session.messages.last?.text?.count     // streaming grew the last bubble's text in place
session.isAgentTyping                  // typing dots appeared / disappeared
session.messages.last?.suggestions     // suggestion pills appeared / changed
session.messages.last?.attachments     // attachments arrived
```

In a view:

```swift
ScrollViewReader { proxy in
    ScrollView {
        LazyVStack(spacing: 8) {
            // ...skeleton / messages / typing dots...

            // Stable scroll anchor — avoids off-by-one when LazyVStack hasn't
            // laid out new bubbles yet.
            Color.clear.frame(height: 1).id("bottom")
        }
    }
    .onChange(of: messages.count)               { _ in scrollToBottom(proxy: proxy) }
    .onChange(of: isAgentTyping)                { _ in scrollToBottom(proxy: proxy) }
    .onChange(of: lastAgentSuggestionCount)     { _ in scrollToBottom(proxy: proxy, delay: true) }
    .onChange(of: lastAgentAttachmentCount)     { _ in scrollToBottom(proxy: proxy, delay: true) }
    // Streaming updates text in place without changing messages.count, so track length too.
    .onChange(of: lastAgentTextLength)          { _ in scrollToBottom(proxy: proxy) }
}
```

> **Streaming:** agent replies grow token-by-token by default (`Configuration.streamingEnabled: true` — ChatGPT-style). The `lastAgentTextLength` watcher above is what keeps the scroll pinned to the bottom while the text grows. See the root README's [*Streaming*](../../../README.md#streaming) section and [`07-Playground`](../07-Playground/) for a live toggle.

**Under the hood:** with `streamingEnabled: true` (the default), `ChatSession` extends the last `.agent` message's `text` on every chunk and re-publishes `messages`. Watching `lastAgentTextLength` (a derived `Int`) gives SwiftUI a stable, scalar signal to drive the scroll — without it, a streaming reply would slide off the bottom of the screen as it grows.

*See [Integration guide › Streaming](../../../README.md#streaming).*

## What this example skips

- runtime configuration knobs (`DevSettings`), raw transport tap, live diagnostics, event log, message timestamps → [`07-Playground/`](../07-Playground/)

---

- **UIKit counterpart:** [`Examples/UIKit/06-FullReference/`](../../UIKit/06-FullReference/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
