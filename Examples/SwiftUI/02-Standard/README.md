# 02-Standard

The 80% chat. Adds typing indicator, connection banner, suggestion pills, delivery state (Sending…/Failed + retry), end + start new chat, and a failure overlay on top of [`01-Hello`](../01-Hello/).

Setup, rendering, and `send()` are unchanged from [`01-Hello`](../01-Hello/) — read it first. This README only covers what's new.

## Run it

```bash
open StandardSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## New in this level

- `Components/MessageBubbleView.swift` — per-message bubble; renders delivery state (Sending… / Failed + tap-to-retry).
- `Components/ConnectionBanner.swift` — yellow "Reconnecting…" pill, shown only during reconnects.
- `Components/SuggestionRow.swift` — horizontal quick-reply chips.
- `Components/TypingIndicator.swift` — animated agent typing dots.

`01-Hello`'s single `ContentView` becomes `Views/ContentView.swift` here — the chat scaffold every later level extends.

## How it works

### Typing indicator — `Views/ContentView.swift`

**Under the hood:** `isAgentTyping` is SDK-managed — true while the agent composes (driven by its thinking/streaming signals), auto-cleared on the next agent message or after the typing timeout (~10s), so you never run a timer. `sendTyping()` throttles outgoing STARTED to ≤1 per 3s and auto-emits STOPPED ~5s after your last call, so it's safe to fire on every keystroke.

Throttled-safe: call on every keystroke; the SDK rate-limits internally. `session.isAgentTyping` drives the animated dots (`Components/TypingIndicator.swift`).

```swift
TextField("Message...", text: $input)
    .onChange(of: input) { _ in Task { await session.sendTyping() } }

if session.isAgentTyping {
    TypingIndicator(avatarUrl: session.lastAgentMessage?.avatarUrl)
        .frame(maxWidth: .infinity, alignment: .leading)
}
```

*See [Build your own UI › Typing](../../../README.md#typing).*

### Connection banner — `Components/ConnectionBanner.swift`

**Under the hood:** `session.connection` is SDK-driven — a transient drop surfaces as `.open → .reconnecting(n) → .open` (auto-reconnect with backoff and jitter, no `.closed` flash), so you only need to show a banner on `.reconnecting`. `.failed` arrives only after the reconnect budget is exhausted.

Only renders during reconnects so a brief drop doesn't show a full-screen blocker.

```swift
if case .reconnecting = status {
    HStack(spacing: 8) {
        ProgressView().scaleEffect(0.7)
        Text("Reconnecting...").font(.caption).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
    .background(Color(.systemYellow).opacity(0.15))
}
```

*See [Build your own UI › Connection & reconnect](../../../README.md#connection--reconnect).*

### Suggestion pills — `Components/SuggestionRow.swift`

**Under the hood:** `AgentMessage.suggestions` are quick replies the agent attached to *that* message (agent messages only); `clearSuggestions(for:)` empties them in the model so the pills vanish. Show them only on the latest agent message.

Pills render **under the last agent message** (inside `MessageBubbleView`), so they
sit with the reply that offered them and scroll with the conversation. They show
only while the agent's message is the last one — as soon as the user sends, their
message becomes last and the pills clear until the agent replies again. Tapping a
pill clears the suggestion locally, then sends its text.

```swift
// ContentView gates each bubble on "is this the last message?":
MessageBubbleView(
    message: message,
    onRetry: { text in Task { try? await session.send(text) } },
    showSendingLabel: showSendingLabel(for: message),
    showSuggestions: !session.hasEnded && message.id == session.messages.last?.id,
    onSuggestionTap: { text in
        session.clearSuggestions(for: message.id)
        Task { try? await session.send(text) }
    }
)

// MessageBubbleView renders them under the agent bubble:
if showSuggestions && !m.suggestions.isEmpty {
    SuggestionRow(suggestions: m.suggestions.map { $0.messageText }) { s in
        onSuggestionTap?(s)
    }
}
```

*See [Build your own UI › Suggestions](../../../README.md#suggestions-quick-replies).*

### End chat + Start new chat — `Views/ContentView.swift`

**Under the hood:** `ChatSession` is `@MainActor`, so all these state reads/writes happen on the main thread — bind directly. `startNewSession()` creates a fresh session and, when the session id changes, `ChatSession` clears `messages` and resets the latched flags for you.

`session.end()` flips `hasEnded`. Swap the input bar for a "Chat ended" footer.

```swift
if session.hasEnded {
    chatEndedFooter            // "conversation ended" + Start New Conversation button
} else {
    inputBar
}

// chatEndedFooter
Button { Task { try? await session.client.startNewSession() } } label: {
    Text("Start New Conversation").font(.subheadline.bold())
}
```

`startNewSession()` creates a fresh session; `ChatSession` clears `messages` and resets `hasEnded` automatically when the session id changes.

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### Delivery state + retry — `Components/MessageBubbleView.swift`

**Under the hood:** `UserMessage.delivery` is optimistic — `.pending` immediately, then the SDK matches the server echo (via a local id) → `.sent`; if no echo arrives it retries (up to 3×) then settles on `.failed`. You only render it; `removeMessage(draftId:)` drops a failed draft so a retry doesn't leave a duplicate.

A user message's `delivery` (`.pending` / `.failed` / `.sent`) drives the "Sending…" / "Tap to retry" labels. On failure, tap the bubble to resend its text.

```swift
case .user(let m):
    if m.delivery == .failed {
        Button { onRetry?(m.text) } label: {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
        }
    }
    Text(m.text)
        .background(m.delivery == .failed ? Color.red.opacity(0.15) : Color.blue)
    if showSendingLabel && m.delivery == .pending {
        Text("Sending...").font(.caption2).foregroundColor(.secondary)
    } else if m.delivery == .failed {
        Text("Tap to retry").font(.caption2).foregroundColor(.red)
    }
```

*See [Build your own UI › Delivery state & retry](../../../README.md#delivery-state--retry).*

### Failure overlay — `Views/ContentView.swift`

**Under the hood:** `failureReason` is set whenever the chat can't auto-recover — an invalid `connectorToken` rejected at the initial connect, the auto-reconnect budget exhausted, or the session expiring. Recovery is consumer-driven — call `client.resume()` to restart the connection.

When `failureReason` is set, offer a manual retry. `String(describing: reason)` is intentional — `PolyError` doesn't conform to `LocalizedError`, so `.localizedDescription` is the generic "The operation couldn't be completed".

```swift
if let reason = session.failureReason {
    VStack(spacing: 12) {
        Text("Connection lost").font(.headline)
        Text(String(describing: reason)).font(.caption).foregroundColor(.secondary)
        Button("Reconnect") {
            Task { try? await session.client.resume() }
        }
    }
}
```

*See [Build your own UI › Connection & reconnect](../../../README.md#connection--reconnect).*

### Keyboard handling — `Views/ContentView.swift`

`scrollDismissesKeyboard` is iOS 16+. Wrapped with an availability check so the example still compiles on iOS 15.

```swift
private struct InteractiveKeyboardDismiss: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16, *) { content.scrollDismissesKeyboard(.interactively) }
        else { content }
    }
}
```

*See [Build your own UI › Avatars & keyboard](../../../README.md#avatars--keyboard).*

## What this example skips

- attachments, URL cards, call actions → [`03-RichContent/`](../03-RichContent/)
- offline detection, terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

## Copy these into your app

The views here use only **public SDK types** (`ChatMessage`, `ResponseSuggestion`,
`ConnectionStatus`), so they drop into any app with the package. Add the package
(root [README → Install](../../../README.md#install)), copy the component files you
need, and drive them from `ChatSession`. Full walkthrough: root
[README → "Build your own UI"](../../../README.md#build-your-own-ui).

---

UIKit counterpart: [`Examples/UIKit/02-Standard/`](../../UIKit/02-Standard/). When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** that counterpart. See `SKILL.md §12`.
