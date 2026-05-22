# 06-FullReference

The complete reference app — the most extensive example in the ladder, and the
**canonical source for [`Examples/Components/`](../../Components/)** (the copy-from
component library every other level mirrors). It's the only level with the full
**connect → loading → chat → error** flow wired end to end, on top of
[`05-Handoff`](../05-Handoff/).

Treat 02–05 as the per-feature tutorials; 06 is how every one of those features
fits together in a real, shippable app, plus the production-only plumbing the
lighter levels skip (a screen-state machine, resume-or-start, in-place new chat,
recoverable error routing, debounced labels, and streaming-aware scroll). Use
this README as your **complete index** to the example ladder.

## Run it

```bash
open FullReferenceSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## Everything 06 demonstrates

06 carries the **entire** feature set from across the ladder. Each row links the
matching root section (where the build-your-own-UI recipe lives) and the level it
first appeared.

| Feature | First appeared | Root recipe |
|---|---|---|
| Typing indicator | 02-Standard | [Typing](../../../README.md#typing) |
| Suggestions / quick replies | 02-Standard | [Suggestions (quick replies)](../../../README.md#suggestions-quick-replies) |
| Delivery state + retry | 02-Standard | [Delivery state & retry](../../../README.md#delivery-state--retry) |
| Connection / reconnect banner | 02-Standard | [Connection & reconnect](../../../README.md#connection--reconnect) |
| Image attachments | 03-RichContent | [Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons) |
| URL cards | 03-RichContent | [Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons) |
| Call action buttons | 03-RichContent | [Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons) |
| Rich text / Markdown | 03-RichContent | [Rich text & links](../../../README.md#rich-text--links) |
| Device-offline banner | 04-Resilience | [Connection & reconnect](../../../README.md#connection--reconnect) |
| Loading skeleton / empty state | 04-Resilience | [Loading & empty states](../../../README.md#loading--empty-states) |
| Live-agent handoff | 05-Handoff | [Live agent handoff](../../../README.md#live-agent-handoff) |

The rendering components that draw all of the above —
`Components/MessageBubbleView`, `Components/AttachmentCarousel`,
`Components/SuggestionRow`, `Components/TypingIndicator`,
`Components/LoadingSkeleton`, `Components/RetryableAsyncImage`,
`Components/RichText`, `Components/CallActionButton`, plus
`Helpers/NetworkMonitor` and `Helpers/InteractiveKeyboardDismiss` — are the exact
files promoted into [`Examples/Components/`](../../Components/). See the level
where each first appeared for a focused walk-through.

## What's unique to 06 (the production layer)

These are the patterns 02–05 don't have. Everything below is real code from this
app — copy-paste ready against the public SDK.

### Screen-state machine — `Views/ContentView.swift`

**Under the hood:** 06 models the whole app as one explicit state enum and swaps
the screen on it; the SDK's lifecycle streams (`client.events`,
`client.connectionStatus`, `client.sessionState`) drive the transitions, so the
UI is always a pure function of where the session is.

```swift
enum AppScreen: Equatable {
    case connect
    case loading
    case chat
    case error(message: String)
}

@ViewBuilder
private var currentScreen: some View {
    switch screen {
    case .connect:      ConnectView(/* ... */)
    case .loading:      LoadingView()
    case .chat:         if let session { ChatScreen(session: session, /* ... */) }
    case .error(let msg): ErrorScreen(message: msg, onBack: { screen = .connect })
    }
}
```

### Resume or start fresh — `Views/ConnectView.swift`

**Under the hood:** `chat()` resumes the persisted session when it's still valid
(within the session timeout) and otherwise creates a fresh one, so a conversation
survives an app relaunch; `start()` always discards any stored session.
`hasResumableSession()` probes the on-disk store with no side effects, so the
connect screen offers "Resume" only when it would actually work.

ConnectView decides which button to show, and ContentView routes the tap to the
right facade call:

```swift
// ConnectView.swift — pick the label from what's resumable
let primaryShowsResume = hasActiveSession || canResume
Button { onResume() } label: {
    Text(primaryShowsResume ? "Resume Chat" : "Start Chat")
}
if primaryShowsResume {
    Button { onStartNew() } label: { Text("Start New Chat") }
}
```

```swift
// ContentView.swift — canResume comes from the SDK, then the facade is picked
ConnectView(
    hasActiveSession: session != nil,
    canResume: PolyMessaging.hasResumableSession(),
    onResume:   { configureAndStart(forceFresh: false) },
    onStartNew: { configureAndStart(forceFresh: true) }
)

let s = forceFresh ? PolyMessaging.start() : PolyMessaging.chat()
session = s
screen = .loading
```

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### Loading screen — `Views/LoadingView.swift`

**Under the hood:** `.loading` is shown the moment a facade call returns, and is
swapped out only when the SDK confirms the session is live — `sessionState.isReady`
(or a `.sessionStart` event) flips it to `.chat`. You never poll; you react to the
stream.

```swift
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().scaleEffect(1.5)
            Text("Connecting...").font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }
}
```

### Error screen + how errors route to it — `Views/ErrorScreen.swift`, `Views/ContentView.swift`

**Under the hood:** there is no separate "failed" flag to read — 06's terminal
error is just the `AppScreen.error(message:)` case. Connect/lifecycle failures
arriving on the SDK's streams (a `.disconnected(error)` event, a
`connectionStatus == .failed`, or a `sessionState.isError`) are translated into
`.error(message:)` only while still on `.loading`, so a mid-chat blip never throws
the user out of the conversation. "Go Back" routes to `.connect`.

```swift
// ContentView.swift — lifecycle streams set the error screen while loading
Task {
    for await event in client.events {
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
        if state.isReady, screen == .loading || screen.isError { screen = .chat }
        if state.isError, screen == .loading {
            screen = .error(message: state.errorMessage ?? "Couldn't start the session.")
        }
    }
}
```

```swift
// ErrorScreen.swift — recoverable: one button back to connect
struct ErrorScreen: View {
    let message: String
    let onBack: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Something went wrong").font(.headline)
            Text(message).multilineTextAlignment(.center)
            Button(action: onBack) { Text("Go Back") }
        }
    }
}
```

### Start a new conversation in place — `Views/ContentView.swift`

**Under the hood:** `clearChat()` wipes the local transcript immediately, while
`startNewSession()` ends the current chat and creates a new one on the *same*
client; when `ChatSession` detects the new session id it auto-clears `messages`
and resets its latched flags, so the screen converges on a clean conversation
without leaving `.chat`.

```swift
private func startNewConversationInPlace() {
    guard let s = session else { return }
    s.clearChat()
    Task {
        try? await s.client.startNewSession()
    }
}
```

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### End → back to connect — `Views/ContentView.swift`

**Under the hood:** `end()` tears down the server-side session for good (it can't
be resumed afterwards). 06 awaits it, then drops the local `session` and routes
back to `.connect`, so the next launch starts the resume-or-start flow afresh. A
destructive confirmation alert guards it.

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

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### Delayed "Sending…" label — `Views/ContentView.swift`

**Under the hood:** the SDK already tracks real delivery (`.pending` → `.sent`);
the ~500ms delay is purely app-side polish on *showing* the label, so fast
confirmations never flash "Sending…". It does not change how or when the SDK
reports delivery — it only gates the label, then drops it the instant the draft
leaves `.pending`.

```swift
// fires per pending draft; only shows the label if still pending after 500ms
Task { @MainActor in
    try? await Task.sleep(nanoseconds: 500_000_000)
    guard case .user(let current) = session.messages.first(where: { $0.id == id }),
          current.delivery == .pending else { return }
    sendingLabels.insert(id)
}
```

*See [Build your own UI › Delivery state & retry](../../../README.md#delivery-state--retry).*

### Retry removes the failed draft, then re-sends — `Views/ContentView.swift`

**Under the hood:** a failed optimistic message is a real draft in `messages`
keyed by its draft id. Retry calls `removeMessage(draftId:)` to drop the stale
bubble, then re-sends the text as a fresh draft — so you never end up with a
duplicate "Failed" bubble lingering next to the new attempt.

```swift
onRetry: { text, draftId in
    if let draftId { session.removeMessage(draftId: draftId) }
    onSend(text)
}
```

*See [Build your own UI › Delivery state & retry](../../../README.md#delivery-state--retry).*

### Streaming-aware scroll restoration — `Views/ChatView.swift`

**Under the hood:** streaming agent replies grow the *text* of an existing bubble
without changing `messages.count`, so a naive "scroll on new message" misses
them. 06 keeps a stable `"bottom"` anchor (a 1pt clear view at the end of the
`LazyVStack`) and re-scrolls to it on every signal that can change content height:
message count, the typing indicator, suggestion/attachment counts, *and* the last
agent message's text length. Staggered scrolls on appear cover bubbles that may
already exist or still be streaming when the view mounts.

```swift
// Stable scroll anchor — avoids off-by-one when LazyVStack hasn't laid out new bubbles yet.
Color.clear.frame(height: 1).id("bottom")
```

```swift
.onChange(of: messages.count)        { _ in scrollToBottom(proxy: proxy) }
.onChange(of: isAgentTyping)         { typing in scrollToBottom(proxy: proxy) }
.onChange(of: lastAgentSuggestionCount) { _ in scrollToBottom(proxy: proxy, delay: true) }
.onChange(of: lastAgentAttachmentCount) { _ in scrollToBottom(proxy: proxy, delay: true) }
// Streaming updates text in place without changing messages.count, so track length too.
.onChange(of: lastAgentTextLength)   { _ in scrollToBottom(proxy: proxy) }
```

## What it skips → where next

06 is a clean production app with no debug surfaces. The developer playground in
[`07-Playground`](../07-Playground/) layers on:

- runtime `DevSettings` configuration knobs (connector token, environment, toggles)
- a raw-transport tap for sending and inspecting protocol frames directly
- diagnostics, message timestamps, and a live event log
- progressive streaming made visible

---

**Cross-framework counterpart:** the UIKit twin of this app is
[`Examples/UIKit/06-FullReference/`](../../UIKit/06-FullReference/) — same feature
set, same connector-token wiring; only the UI binding differs.

Add the package via root [README → Install](../../../README.md#install), then
follow root [README → Build your own UI](../../../README.md#build-your-own-ui) to
drive these components from `ChatSession`.

When you change this example, update the matching snippets in the project
[`README.md`](../../../README.md) **and** the UIKit counterpart at
[`Examples/UIKit/06-FullReference/`](../../UIKit/06-FullReference/). See `SKILL.md §12`.
