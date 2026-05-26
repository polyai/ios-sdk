# 02-Standard (SwiftUI)

The 80% chat — adds typing indicator, connection banner, suggestion pills, delivery state (`Sending…` / `Failed` + retry), end + start new chat, and a failure overlay on top of [`01-Hello`](../01-Hello/).

Setup, rendering, and `send()` are unchanged from [`01-Hello`](../01-Hello/) — read it first. This README only covers what's new.

## Run it

```bash
open StandardSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your connector token in `App/StandardApp.swift` (currently `"YOUR_CONNECTOR_TOKEN"`).

## What this example demonstrates

- Typing indicator — `session.isAgentTyping`, `await session.sendTyping()`
- Reconnect banner — `session.connection` (`.reconnecting`)
- Suggestion pills — `AgentMessage.suggestions`, `session.clearSuggestions(for:)`
- End / start-new chat — `try await session.end()`, `session.hasEnded`, `try await session.client.startNewSession()`
- Delivery state + retry — `UserMessage.delivery`, `session.removeMessage(draftId:)`
- Failure overlay — `session.failureReason`, `try await session.client.resume()`
- Keyboard dismiss — `scrollDismissesKeyboard(.interactively)` with an iOS-15 fallback

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them composed into one chat view.

## How it works

Each subsection leads with **the SDK call(s)** (the actual API), then shows **how it's wired into the chat view**.

### Typing indicator — `Views/ContentView.swift`

Listen for the agent + announce your own typing:

```swift
await session.sendTyping()      // call on every keystroke (SDK throttles)
session.isAgentTyping           // Bool — drive the "agent is typing…" UI
session.lastAgentMessage        // AgentMessage? — handy for the avatar next to the dots
```

In a view:

```swift
var body: some View {
    VStack {
        // ...message list (above)...

        if session.isAgentTyping {
            TypingDots(avatarUrl: session.lastAgentMessage?.avatarUrl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        TextField("Message...", text: $input)
            .onChange(of: input) { _ in Task { await session.sendTyping() } }

        // ...send button (later section)...
    }
}
```

`TypingDots` is your own small view (the example has one inside `Components/`).

**Under the hood:** `isAgentTyping` is SDK-managed — true while the agent composes (driven by its thinking/streaming signals), auto-cleared on the next agent message or after the typing timeout (~10s), so you never run a timer. `sendTyping()` throttles outgoing STARTED frames to ≤1 per 3s and auto-emits STOPPED ~5s after your last call, so it's safe to fire on every keystroke.

*See [Integration guide › Typing](../../../README.md#typing).*

### Connection banner — `Views/ContentView.swift`

Show only during transient reconnects:

```swift
session.connection              // ConnectionStatus — show a banner only on .reconnecting
```

In a view:

```swift
var body: some View {
    VStack(spacing: 0) {
        if case .reconnecting = session.connection {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Reconnecting...").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(.systemYellow).opacity(0.15))
        }

        // ...message list + composer (above / below)...
    }
}
```

**Under the hood:** `session.connection` is SDK-driven — a transient drop surfaces as `.open → .reconnecting(n) → .open` (auto-reconnect with backoff and jitter, no `.closed` flash), so you only need to show a banner on `.reconnecting`. `.failed` arrives only after the reconnect budget is exhausted (handled by the failure overlay below).

*See [Integration guide › Connection & reconnect](../../../README.md#connection--reconnect).*

### Suggestion pills — under the last agent message

Render + dismiss the agent's quick replies:

```swift
agent.suggestions               // [ResponseSuggestion] on an AgentMessage
session.clearSuggestions(for: message.id)  // empties them locally so pills vanish
try? await session.send(suggestion.messageText)
```

In a view — pills render under the last message and clear when the user sends:

```swift
ForEach(session.messages) { message in
    // ...your bubble rendering for this message...

    if case .agent(let agent) = message,
       message.id == session.messages.last?.id,
       !session.hasEnded,
       !agent.suggestions.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(agent.suggestions, id: \.messageText) { suggestion in
                    Button(suggestion.messageText) {
                        session.clearSuggestions(for: message.id)
                        Task { try? await session.send(suggestion.messageText) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
```

Pills sit with the reply that offered them and scroll with the conversation. They show only while the agent's message is the last one — as soon as the user sends, their message becomes last and the pills disappear until the agent replies again.

**Under the hood:** `AgentMessage.suggestions` are quick replies the agent attached to *that* message (agent messages only). `clearSuggestions(for:)` empties them in the model so the pills vanish before `send(_:)` resolves — feels instant.

*See [Integration guide › Suggestions](../../../README.md#suggestions-quick-replies).*

### End chat + Start new chat — `Views/ContentView.swift`

End the session + start a fresh one:

```swift
try await session.end()                       // flips hasEnded; conversation is over
session.hasEnded                              // Bool — swap composer for a "Start new" footer
try await session.client.startNewSession()    // begin a fresh conversation on the same surface
```

In a view:

```swift
var body: some View {
    VStack {
        // ...message list (above)...

        if session.hasEnded {
            VStack(spacing: 10) {
                Text("This conversation has ended.")
                    .font(.subheadline).foregroundColor(.secondary)
                Button("Start New Conversation") {
                    Task { try? await session.client.startNewSession() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        } else {
            // ...composer...
        }
    }
    .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
            if !session.hasEnded {
                Button("End Chat") { Task { try? await session.end() } }
            }
        }
    }
}
```

**Under the hood:** `session.end()` flips `hasEnded`. `startNewSession()` creates a fresh session — when the session id changes, `ChatSession` clears `messages` and resets the latched flags for you, so no view bookkeeping needed.

*See [Integration guide › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### Delivery state + retry — inside the `.user` bubble

Track delivery + retry a failed send:

```swift
m.delivery                                    // Delivery — .pending / .sent / .failed
session.removeMessage(draftId: m.draftId)     // drop the failed draft before re-sending
try? await session.send(m.text)               // re-send the same text
```

In a view — restyle the `.user` bubble per state:

```swift
ForEach(session.messages) { message in
    switch message {
    case .user(let m):
        VStack(alignment: .trailing, spacing: 2) {
            Text(m.text).padding(10)
                .background(m.delivery == .failed ? Color.red.opacity(0.15) : .blue)
            if m.delivery == .failed {
                Button("Tap to retry") {
                    session.removeMessage(draftId: m.draftId)
                    Task { try? await session.send(m.text) }
                }
            } else if m.delivery == .pending {
                Text("Sending…").font(.caption2).foregroundStyle(.secondary)
            }
        }

    // ...other cases (.agent, .system) — see the core pattern...
    default: EmptyView()
    }
}
```

**Tip:** delay the "Sending…" label by ~500 ms so fast confirmations don't flash it.

**Under the hood:** `UserMessage.delivery` is optimistic — `.pending` immediately, then the SDK matches the server echo (via a local id) → `.sent`; if no echo arrives after retries (up to 3×) it settles on `.failed`. You only render it; `removeMessage(draftId:)` drops the failed draft so a retry doesn't leave a duplicate bubble.

*See [Integration guide › Delivery state & retry](../../../README.md#delivery-state--retry).*

### Failure overlay — `Views/ContentView.swift`

Surface a terminal failure + offer retry:

```swift
session.failureReason                         // PolyError? — non-nil on terminal failure
try await session.client.resume()             // call this from the overlay's retry button
```

In a view:

```swift
var body: some View {
    VStack {
        // ...message list + composer (above)...
    }
    .overlay {
        if let reason = session.failureReason {
            VStack(spacing: 12) {
                Text("Connection lost").font(.headline)
                // PolyError isn't LocalizedError, so use String(describing:).
                Text(String(describing: reason))
                    .font(.caption).foregroundColor(.secondary)
                Button("Reconnect") {
                    Task { try? await session.client.resume() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(32)
        }
    }
}
```

**Under the hood:** `failureReason` is set whenever the chat can't auto-recover — an invalid `connectorToken` rejected at the initial connect, the auto-reconnect budget exhausted, or the session expiring. Recovery is consumer-driven — call `client.resume()` to retry.

*See [Integration guide › Terminal errors](../../../README.md#terminal-errors).*

### Keyboard handling — `Views/ContentView.swift`

The SDK doesn't get involved here — it's pure SwiftUI. `scrollDismissesKeyboard` is iOS 16+, so guard it:

```swift
struct InteractiveKeyboardDismiss: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}

// Then on your ScrollView:
ScrollView { /* messages */ }.modifier(InteractiveKeyboardDismiss())
```

*See [Integration guide › Avatars & keyboard](../../../README.md#avatars--keyboard).*

## What this example skips

- attachments, URL cards, call actions → [`03-RichContent/`](../03-RichContent/)
- offline detection, full-screen terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

---

- **UIKit counterpart:** [`Examples/UIKit/02-Standard/`](../../UIKit/02-Standard/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
