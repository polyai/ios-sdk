# 01-Hello (SwiftUI)

The smallest possible chat — initialize the SDK, render messages, send one. About 50 lines of view code.

## Run it

```bash
open HelloSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your API key in `HelloApp.swift` (currently `"YOUR_API_KEY"`).

## What this example demonstrates

- `PolyMessaging.initialize(_:)` once at launch
- `PolyMessaging.chat()` for a session, observed via `@StateObject`
- Render `session.messages` with a `ScrollView` + `LazyVStack`
- Auto-scroll as the agent's reply streams in
- Send with `try? await session.send(text)`
- Surface terminal failures (invalid token) via `.alert` bound to `session.failureReason`

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them as one concrete file.

## How it works

Each subsection leads with **the SDK call** (one line — the actual API), then shows **how it's wired into a view**.

### Initialize once at app launch — `HelloApp.swift`

Configure the SDK once at launch:

```swift
PolyMessaging.initialize(.init(
    apiKey: "YOUR_API_KEY",  // from Agent Studio → Connector Settings
    environment: .dev                        // .production / .cluster("us-1") / .staging / .dev / .custom(...)
))
```

In an `@main` App:

```swift
@main
struct HelloApp: App {
    init() {
        PolyMessaging.initialize(.init(
            apiKey: "YOUR_API_KEY",
            environment: .dev
        ))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

After this, `PolyMessaging.chat()` works from any view.

**Under the hood:** `initialize` just stashes your API key and environment process-wide — no network happens yet. The work starts when you call `chat()`.

*See [Quick start](../../../README.md#quick-start).*

### Get a session and render messages — `ContentView.swift`

Create a session + subscribe to its messages:

```swift
let session = PolyMessaging.chat()    // Resume the previous conversation if one exists within the
                                      // session timeout (default 10 min), else start a fresh one.
                                      // — use `start()` instead to always start fresh.

session.messages                      // [ChatMessage], @Published — the whole transcript. Cases:
                                      //   .user(UserMessage) / .agent(AgentMessage) / .system(SystemMessage)

session.isReady                       // Bool — false until WebSocket + agent-join complete
```

In a view:

```swift
struct ContentView: View {
    @StateObject var session = PolyMessaging.chat()
    @State private var input = ""

    var body: some View {
        VStack {
            // ...message list (see "Scroll as the agent types" below)...
            // ...composer (see "Send a message" below)...
        }
    }
}
```

`@StateObject` keeps one session per view lifecycle. `session.messages` is `@Published`, so SwiftUI re-renders any reads of it when the SDK updates the transcript.

**Streaming is on by default** — `Configuration.streamingEnabled` defaults to `true`, so agent replies grow token-by-token (ChatGPT-style). To switch to complete-message bubbles instead, set `streamingEnabled: false` in `HelloApp.swift`. See the root README's [Streaming](../../../README.md#streaming) section.

**Under the hood:** `chat()` runs the whole REST + WebSocket handshake, agent-join, and resume-or-create for you; `isReady` flips true once it's connected. `messages` is the SDK-maintained transcript (`.user` / `.agent` / `.system`) that republishes on every change, so your list just re-renders.

*See [Integration guide › The core pattern](../../../README.md#the-core-pattern-render-messages-yourself).*

### Scroll as the agent types — `ContentView.swift`

Signals that trigger an auto-scroll:

```swift
session.messages.count          // Int — grows when a new bubble (user / agent / system) arrives

session.messages.last?.text     // String? — grows in place while the last reply streams (count unchanged)
```

In a view:

```swift
var body: some View {
    VStack {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.messages) { message in
                        Text(message.text ?? "")
                            .padding(10).background(Color(.systemGray6)).cornerRadius(12)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: session.messages.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // Streaming grows the last bubble's text without changing messages.count.
            .onChange(of: session.messages.last?.text ?? "") { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }

        // ...composer (next section)...
    }
}
```

Streaming grows the last agent message's `text` in place — `messages.count` doesn't change, so a single `.onChange(of: messages.count)` isn't enough. The `Color.clear.id("bottom")` sentinel is what `proxy.scrollTo` targets on either signal.

**Under the hood:** with `streamingEnabled: true` (the default), `ChatSession` extends the last `.agent` message's `text` on every chunk and re-publishes `messages`. SwiftUI re-evaluates `Text(message.text ?? "")` and re-fires `.onChange(of: messages.last?.text)` — the scroll tracks the reply as it grows.

*See [Integration guide › Streaming](../../../README.md#streaming).*

### Send a message — `ContentView.swift`

Send a user message (optimistic):

```swift
try? await session.send(text)   // throws PolyError; the bubble appears in `messages`
                                // immediately as .pending, then settles into .sent or .failed
```

In a view:

```swift
var body: some View {
    VStack {
        // ...message list (above)...

        HStack {
            TextField("Message...", text: $input)
                .textFieldStyle(.roundedBorder)
            Button("Send") {
                let text = input; input = ""
                Task { try? await session.send(text) }
            }
            .disabled(input.isEmpty || session.hasEnded)
        }
        .padding()
    }
}
```

Sending stays available even while offline or reconnecting — gate only on `hasEnded` (and empty text), **not** on connection readiness. `send(_:)` is optimistic, so a message typed before the socket is up is queued and delivered once it connects. `hasEnded` becomes true after `session.end()`. (The UIKit twin makes the same choice.)

**Under the hood:** `send(text)` is optimistic — the bubble appears in `messages` immediately while the SDK manages delivery and the server echo behind the scenes. `ChatSession` is `@MainActor`, so call it from the main thread.

*See [Integration guide › The core pattern](../../../README.md#the-core-pattern-render-messages-yourself).*

### Catch a bad API key — `ContentView.swift`

Detect a terminal failure + offer retry:

```swift
session.failureReason   // PolyError? — non-nil when the chat can't auto-recover:
                        //   invalid apiKey (initial connect 401/403),
                        //   reconnect budget exhausted,
                        //   session expired (idle past sessionTimeoutSeconds, default 10 min)

try await session.client.resume()   // manually re-attempt the connection
```

In a view:

```swift
private var failureAlertBinding: Binding<Bool> {
    Binding(get: { session.failureReason != nil }, set: { _ in })
}

var body: some View {
    VStack {
        // ...message list + composer (above)...
    }
    .alert("Couldn't connect", isPresented: failureAlertBinding) {
        Button("Try Again") {
            Task { try? await session.client.resume() }
        }
    } message: {
        Text(session.failureReason.map { String(describing: $0) } ?? "")
    }
}
```

`String(describing:)` is intentional — `PolyError` doesn't conform to `LocalizedError`, so `.localizedDescription` is the generic "The operation couldn't be completed". `String(describing:)` gives the case name (`auth(unauthorized)`) which is far more useful.

**Under the hood:** `failureReason` is fed by both `client.connectionStatus.failed` (reconnect budget exhausted, session expired) **and** the initial-connect path that catches an unauthorized REST response and flags `sessionState.hasInvalidConnectorToken`. Either way you get a single source of truth for "the chat can't recover from this".

*See [Integration guide › Terminal errors](../../../README.md#terminal-errors).*

## What this example skips

- typing indicator, connection banner, delivery dots, suggestions, end button → [`02-Standard/`](../02-Standard/)
- attachments, URL cards, call actions → [`03-RichContent/`](../03-RichContent/)
- offline detection, full-screen terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

---

- **UIKit counterpart:** [`Examples/UIKit/01-Hello/`](../../UIKit/01-Hello/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
