# PolyMessaging iOS SDK

![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-green)

Add AI-powered chat to your iOS app. The SDK handles token auth, the WebSocket, streaming, reconnection, delivery tracking, and live-agent handoff — you build (or copy) the UI.

**Two ways to build, depending on how much control you want:**

- **[Quick start](#quick-start--drop-in-our-ui)** — copy our prebuilt SwiftUI/UIKit components, bind a `ChatSession`, and you have a working chat in minutes.
- **[Build your own UI](#build-your-own-ui)** — observe one object (`ChatSession`) and render the chat however you like, in your own views. This is where you'll understand the SDK well enough to fit it into any app.

Reference: [Configuration](#configuration) · [Error handling](#error-handling) · [How it works](#how-it-works) · [Raw transport](#advanced-raw-transport) · [Example apps](#example-apps).

## Features

| | Feature | Description |
|---|---|---|
| 💬 | **Messaging** | Send and receive messages over WebSocket with typed Swift events |
| ⚡ | **Streaming** | Real-time chunks, auto-assembled — optionally rendered token-by-token |
| 🔄 | **Reconnection** | Automatic backoff + jitter, session resume, drops dead sockets the instant the OS reports offline |
| 🔐 | **Auth** | Token acquisition and session lifecycle — fully managed |
| 👤 | **Live agent** | Seamless handoff to humans with queue status and typing |
| 💡 | **Suggestions** | Quick-reply pills the agent offers, tap to send |
| 📎 | **Attachments** | Images, link cards, call-to-action phone buttons |
| 📡 | **Delivery tracking** | Optimistic send → confirmed → failed, per message |
| 🔧 | **Escape hatch** | Drop to the raw WebSocket transport for advanced use cases |

## Install

Add the package by its Git URL, pinned to a version.

**In Xcode** — File → Add Package Dependencies → paste the URL → Dependency Rule "Up to Next Major Version" `0.2.1` → Add Package → tick the **PolyMessaging** library for your app target:

```
https://github.com/PolyAI-LDN/poly_messaging_ios
```

**In `Package.swift`:**

```swift
dependencies: [
    .package(url: "https://github.com/PolyAI-LDN/poly_messaging_ios", from: "0.2.1")
]
// then add to your target:
.product(name: "PolyMessaging", package: "poly_messaging_ios")
```

Then initialize once at launch (same for both tracks):

```swift
// SwiftUI — in your @main App init; UIKit — in AppDelegate.didFinishLaunching.
PolyMessaging.initialize(.init(
    connectorToken: "your_token",     // Agent Studio → Connector Settings
    environment: .cluster("us-1")     // regional routing
))
```

> Your app's bundle identifier is sent automatically as the `X-Host` header — it must match the host registered in Agent Studio for your connector token.

---

# Quick start — drop in our UI

The fastest path: copy our prebuilt components and bind a `ChatSession`. You get bubbles, delivery state, suggestion pills, typing, attachments, and a reconnect banner — all wired.

**1. Start from 02-Standard.** Copy the [02-Standard](Examples/SwiftUI/02-Standard/) example's screen and the views next to it — `ChatView` (SwiftUI) / `ChatViewController` (UIKit) plus the bubble, pill, typing, and banner components in its folder. Each example level is self-contained and internally consistent, so it drops in cleanly (everything takes only public SDK types). [`Examples/Components/`](Examples/Components/) collects the richer **06-FullReference** versions if you'd rather start there — just keep a level's screen and its components together, since the composition roots (`MessageBubbleView` / `MessageCell`) differ slightly per level.

**2. Bind a `ChatSession` and render it.** `PolyMessaging.chat()` returns a `ChatSession` — an `ObservableObject` holding the whole chat state. The screen below mirrors 02-Standard:

```swift
// SwiftUI — a complete chat screen using our components.
struct ChatView: View {
    @StateObject var session = PolyMessaging.chat()
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            if case .reconnecting = session.connection {            // reconnect banner
                Text("Reconnecting…").font(.caption)
                    .frame(maxWidth: .infinity).padding(6).background(.yellow.opacity(0.15))
            }

            ScrollView {                                            // bubbles + delivery + pills
                LazyVStack(spacing: 8) {
                    ForEach(session.messages) { message in
                        MessageBubbleView(
                            message: message,
                            onRetry: { text in Task { try? await session.send(text) } },
                            showSuggestions: !session.hasEnded && message.id == session.messages.last?.id,
                            onSuggestionTap: { tapped in
                                session.clearSuggestions(for: message.id)
                                Task { try? await session.send(tapped) }
                            }
                        )
                    }
                    if session.isAgentTyping { TypingIndicator(avatarUrl: session.agentAvatarUrl) }
                }.padding()
            }

            if session.hasEnded {                                   // composer → "start new" CTA
                Button("Start New Chat") {
                    session.clearChat()
                    Task { try? await session.client.startNewSession() }
                }.padding()
            } else {
                HStack {
                    TextField("Message", text: $text)
                        .onChange(of: text) { _ in Task { await session.sendTyping() } }
                    Button("Send") {
                        let t = text; text = ""
                        Task { try? await session.send(t) }
                    }.disabled(!session.isReady || text.isEmpty)
                }.padding()
            }
        }
    }
}
```

```swift
// UIKit — the same screen. One Combine sink per piece of state; a diffable data
// source with two row kinds so suggestion pills sit under the last message.
final class ChatViewController: UIViewController {
    private let session = PolyMessaging.chat()
    private let tableView = UITableView()
    private let inputField = UITextField()
    private let reconnectBanner = UILabel()
    private var bag = Set<AnyCancellable>()

    private enum Row: Hashable { case message(UUID); case suggestions(UUID) }
    private var dataSource: UITableViewDiffableDataSource<Int, Row>!

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
        tableView.register(SuggestionsCell.self, forCellReuseIdentifier: SuggestionsCell.reuseID)
        // …lay out reconnectBanner, tableView, inputField, and a send button…
        configureDataSource()

        session.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in self?.render(messages) }
            .store(in: &bag)
        session.$isAgentTyping
            .receive(on: RunLoop.main)
            .sink { [weak self] typing in self?.setTypingIndicatorVisible(typing) }
            .store(in: &bag)
        session.$connection
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.reconnectBanner.isHidden = !status.isReconnecting }
            .store(in: &bag)
        session.$hasEnded
            .receive(on: RunLoop.main)
            .sink { [weak self] ended in self?.inputField.isEnabled = !ended }
            .store(in: &bag)

        inputField.addAction(UIAction { [weak self] _ in
            Task { await self?.session.sendTyping() }
        }, for: .editingChanged)
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, indexPath, row in
            guard let self else { return UITableViewCell() }
            switch row {
            case .message(let id):
                let cell = table.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
                if let message = self.session.messages.first(where: { $0.id == id }) {
                    cell.configure(with: message,
                                   onRetry: { [weak self] text in Task { try? await self?.session.send(text) } })
                }
                return cell
            case .suggestions(let id):
                let cell = table.dequeueReusableCell(withIdentifier: SuggestionsCell.reuseID, for: indexPath) as! SuggestionsCell
                if let message = self.session.messages.first(where: { $0.id == id }) {
                    cell.configure(suggestions: message.suggestions) { [weak self] suggestion in
                        self?.session.clearSuggestions(for: id)
                        Task { try? await self?.session.send(suggestion.messageText) }
                    }
                }
                return cell
            }
        }
    }

    private func render(_ messages: [ChatMessage]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        var rows = messages.map { Row.message($0.id) }
        if !session.hasEnded, let last = messages.last, !last.suggestions.isEmpty {
            rows.append(.suggestions(last.id))
        }
        snapshot.appendItems(rows)
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @objc private func sendTapped() {
        let text = inputField.text ?? ""
        guard !text.isEmpty else { return }
        inputField.text = ""
        Task { try? await session.send(text) }
    }
}
```

**3. Run an example to see it all.** Every feature is wired in the [example ladder](#example-apps) — open any `.xcodeproj` and Cmd+R. To go beyond what the components expose, read **Build your own UI** next.

> **`chat()` vs `start()`** — `chat()` resumes the previous conversation if one exists (within 1 hour), else starts fresh; `start()` always starts fresh. `PolyMessaging.hasResumableSession()` tells you which to offer.
> **Lifecycle:** initialize once; keep one `ChatSession` per chat surface (`@StateObject` / a stored property); call `await session.client.shutdown()` when the surface goes away for good.

---

# Build your own UI

If our components don't fit your design, you don't need them. The entire chat is one observable object — **`ChatSession`** — and building any UI is just: *observe its state, and render it.*

## Meet `ChatSession`

`PolyMessaging.chat()` (or `start()`) returns a `@MainActor` `ChatSession` — an `ObservableObject`. It assembles streaming, tracks delivery, manages typing, dedups resumes, and surfaces handoff — so your UI only ever reads state and calls methods. SwiftUI binds it with `@StateObject`; UIKit sinks its `@Published` properties with Combine.

**State you observe** (all `@Published`, read-only):

| Property | Type | What it tells you |
|---|---|---|
| `messages` | `[ChatMessage]` | the whole transcript — `.user` / `.agent` / `.system` |
| `isReady` | `Bool` | connected and ready to send |
| `connection` | `ConnectionStatus` | socket state — `.connecting` / `.open` / `.reconnecting(n)` / `.failed` / … |
| `isAgentTyping` | `Bool` | show the typing indicator |
| `agentAvatarUrl` | `URL?` | latest agent / live-agent avatar |
| `hasStarted` | `Bool` | the conversation has begun |
| `hasEnded` | `Bool` | conversation is over — swap the composer for a "start new" CTA |
| `failureReason` | `PolyError?` | non-nil once the connection has *terminally* failed |

**Methods you call:**

| Member | What it does |
|---|---|
| `send(_:) async throws` | send a user message (optimistic — appears immediately as `.pending`) |
| `sendTyping() async` | tell the agent you're typing (safe every keystroke; throttled) |
| `end() async throws` | end the conversation |
| `removeMessage(draftId:)` | drop a failed draft (call before re-sending on retry) |
| `clearSuggestions(for:)` | clear one message's quick-reply pills |
| `clearChat()` | wipe the transcript (e.g. before `startNewSession()`) |
| `userMessages` / `agentMessages` / `systemMessages` / `lastAgentMessage` | filtered views of `messages` |
| `client` | the underlying `PolyMessagingClient` — `events`, `startNewSession()`, `resume()`, `shutdown()`, `getConnection()` |

## Starting, resuming & ending a session

`chat()` and `start()` both return a `ChatSession`; the difference is whether they reuse the last conversation:

- **`chat()`** — resume the stored session if it's still valid (within the session timeout, ~1 hour), else start fresh. **This is the default** — conversations survive an app relaunch.
- **`start()`** — always discard any stored session and begin a new one. Use it for an explicit "New chat" entry point.

Before showing the chat, you can offer the choice:

```swift
if PolyMessaging.hasResumableSession() {
    // offer "Resume previous chat?" → PolyMessaging.chat()
} else {
    // PolyMessaging.start()
}
```

Then observe `hasStarted` / `hasEnded` and use these methods on the live session:

| Call | When |
|---|---|
| `try await session.send(text)` | send a message |
| `try await session.end()` | end the conversation (flips `hasEnded`) |
| `session.clearChat()` | wipe the on-screen transcript immediately |
| `try await session.client.startNewSession()` | end the current chat and begin a fresh one **in place** (same `ChatSession`/client) |
| `try await session.client.resume()` | reconnect after a terminal `.failed` (see [Connection & reconnect](#connection--reconnect)) |

A user-initiated `end()` flips `hasEnded` with no "conversation ended" pill; an agent- or server-initiated end shows the pill (it arrives as a `.system` message). For a "Start New Chat" button, call `clearChat()` then `startNewSession()`.

> **Lifecycle & cleanup:** call `PolyMessaging.initialize(...)` once at launch; keep **one** `ChatSession` per chat surface (`@StateObject` in SwiftUI, a stored property in UIKit) — each new session is a fresh REST handshake; and call `await session.client.shutdown()` when the surface is dismissed for good (idempotent — cancels heartbeat, reconnect, and retry tasks). `ChatSession` is `@MainActor`: observe and mutate it from the main actor.

## The core pattern: render `messages` yourself

`messages` is `[ChatMessage]`, where `ChatMessage` is an enum — `.user(UserMessage)`, `.agent(AgentMessage)`, `.system(SystemMessage)`, each `Identifiable`. **Every chat UI is the same shape: iterate `messages` and `switch` over the case.** This one pattern renders *everything* — text, agent vs user, system pills, handoff, live agents.

```swift
// SwiftUI — the whole transcript, your own bubbles. Re-renders automatically
// whenever @Published `messages` changes (new message, delivery update, stream growth).
struct ChatView: View {
    @StateObject var session = PolyMessaging.chat()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(session.messages) { message in
                    switch message {
                    case .user(let m):
                        Text(m.text)                                  // your sent bubble
                            .padding(10).background(.blue).foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    case .agent(let m):
                        Text(m.text)                                  // agent bubble; tint live humans
                            .padding(10)
                            .background(m.agentKind == .live ? Color.teal.opacity(0.18) : Color(.systemGray5))
                    case .system(let m):
                        Text(systemLabel(m.event))                    // centered status pill
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }.padding()
        }
    }
}
```

```swift
// UIKit — sink `messages`, reload, and switch in cellForRowAt. Same shape.
session.$messages
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in self?.tableView.reloadData() }
    .store(in: &bag)

func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { session.messages.count }

func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
    let cell = t.dequeueReusableCell(withIdentifier: "cell", for: i)
    switch session.messages[i.row] {
    case .user(let m):   cell.textLabel?.text = m.text
    case .agent(let m):  cell.textLabel?.text = m.text
    case .system(let m): cell.textLabel?.text = systemLabel(m.event)
    }
    return cell
}
```

**What each case carries** (the fields you render):

- **`UserMessage`** — `text`, `delivery` (`.pending` / `.sent` / `.failed`), `draftId`.
- **`AgentMessage`** — `text` (Markdown), `agentKind` (`.poly` / `.live`), `agentName`, `avatarUrl`, `attachments`, `suggestions`, `callActions`.
- **`SystemMessage`** — `event: SystemEvent` (handoff steps, queue status, conversation-ended, …).

`SystemEvent` is what your `systemLabel(_:)` switches on:

```swift
func systemLabel(_ event: SystemEvent) -> String {
    switch event {
    case .handoffStarted:                    return "Transferring you to an agent…"
    case .queueStatus(let pos, let msg):     return msg ?? pos.map { "You're #\($0) in line" } ?? "Waiting…"
    case .handoffAccepted:                   return "An agent will be with you shortly"
    case .liveAgentJoined(let name):         return "\(name ?? "An agent") joined"
    case .liveAgentLeft, .conversationEnded: return "Conversation ended"
    case .handoffFailed(let reason):         return "Transfer failed: \(reason ?? "unknown")"
    case .handoffTimeout:                    return "No agents available right now"
    case .serverMessage(let text, _):        return text
    default:                                 return ""
    }
}
```

That's the foundation. The rest of this section is just *which field or case* each feature uses — and the component you can copy to skip the boilerplate.

## Adding each feature

Each feature is data already on `ChatSession`. For each: the data, a **SwiftUI** snippet, a **UIKit** snippet, and the **example** it comes from. Copy the named component to skip the boilerplate, or render the field yourself with [the core pattern](#the-core-pattern-render-messages-yourself).

### Typing
**Data:** `isAgentTyping` (+ `agentAvatarUrl`) shows the dots; call `sendTyping()` on every keystroke to tell the agent — throttled, auto-STOPPED after 5 s idle, and `isAgentTyping` clears on the next agent message.

```swift
// SwiftUI
if session.isAgentTyping { TypingIndicator(avatarUrl: session.agentAvatarUrl) }

TextField("Message", text: $text)
    .onChange(of: text) { _ in Task { await session.sendTyping() } }
```
```swift
// UIKit
session.$isAgentTyping
    .receive(on: RunLoop.main)
    .sink { [weak self] typing in self?.setTypingIndicatorVisible(typing) }
    .store(in: &bag)

inputField.addAction(UIAction { [weak self] _ in
    Task { await self?.session.sendTyping() }
}, for: .editingChanged)
```
*Example:* [`TypingIndicator.swift`](Examples/Components/SwiftUI/TypingIndicator.swift) · `TypingDotsView` in [`02-Standard ChatViewController.swift`](Examples/UIKit/02-Standard/Views/ChatViewController.swift)

### Suggestions (quick replies)
**Data:** `AgentMessage.suggestions` (`[ResponseSuggestion]`, agent-only). Render under the last message; on tap, clear then send. Only the latest agent message shows pills, and they scroll away with history.

```swift
// SwiftUI — under the last message (inside MessageBubbleView)
if isLast, !message.suggestions.isEmpty {
    SuggestionRow(suggestions: message.suggestions.map(\.messageText)) { tapped in
        session.clearSuggestions(for: message.id)
        Task { try? await session.send(tapped) }
    }
}
```
```swift
// UIKit — a SuggestionsView in its own row/cell
cell.configure(suggestions: message.suggestions) { [weak self] suggestion in
    self?.session.clearSuggestions(for: message.id)
    Task { try? await self?.session.send(suggestion.messageText) }
}
```
*Example:* [`SuggestionRow.swift`](Examples/Components/SwiftUI/SuggestionRow.swift) · [`SuggestionsView.swift`](Examples/Components/UIKit/SuggestionsView.swift)

### Delivery state & retry
**Data:** `UserMessage.delivery` (`.pending` → `.sent` → `.failed`). Restyle the bubble per state; on `.failed`, drop the draft with `removeMessage(draftId:)` then re-send so you don't duplicate. Tip: delay the "Sending…" label ~500 ms so fast confirmations don't flash it.

```swift
// SwiftUI — your user bubble (in the .user case of the core pattern)
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
```
```swift
// UIKit — style the cell by delivery, and wire the retry button to:
switch m.delivery {
case .pending: statusLabel.text = "Sending…"
case .sent:    statusLabel.isHidden = true
case .failed:  statusLabel.text = "Tap to retry"
}

func retry(_ m: UserMessage) {
    session.removeMessage(draftId: m.draftId)
    Task { try? await session.send(m.text) }
}
```
*Example:* [`MessageBubbleView.swift`](Examples/Components/SwiftUI/MessageBubbleView.swift) · [`MessageCell.swift`](Examples/Components/UIKit/MessageCell.swift)

### Attachments, link cards & call buttons
An agent message can carry images, link preview-cards, and `tel:` call buttons — all on `AgentMessage`. Filter `attachments` by `contentType` and render each kind; drop `.unknown` (it exists for forward-compat).

**Data:** `AgentMessage.attachments` (`[Attachment]`) and `AgentMessage.callActions` (`[ChatCallAction]`).
- `Attachment`: `contentType` (`.image` / `.url` / `.unknown`), `contentUrl`, `previewImageUrl`, `title`, `callToActionText`
- `ChatCallAction`: `title`, `contactNumber`

| Kind | Filter | Component — SwiftUI · UIKit | Renders |
|---|---|---|---|
| Image | `contentType == .image` | `AttachmentCarousel` · `AttachmentCarouselView` | horizontal strip of image cards |
| Link card | `contentType == .url` | `URLCard` (03; 06 folds into `AttachmentCarousel`) · `URLCardView` | preview image + title + CTA |
| Call button | `callActions` | `CallActionButton` · `CallActionsRow` | green button that dials `tel:` |

```swift
// SwiftUI — in the agent branch of your bubble (see the core pattern):
let images = m.attachments.filter { $0.contentType == .image }
if !images.isEmpty { AttachmentCarousel(attachments: images) }

ForEach(Array(m.attachments.filter { $0.contentType == .url }.enumerated()), id: \.offset) { _, att in
    URLCard(attachment: att)
}
ForEach(m.callActions) { CallActionButton(action: $0) }
```
```swift
// UIKit — in your cell, feed each view its slice of the attachments:
imageCarousel.configure(with: m.attachments.filter { $0.contentType == .image })
urlCarousel.configure(with:   m.attachments.filter { $0.contentType == .url })
callActionsRow.configure(actions: m.callActions)
```

Each card opens `contentUrl` on tap; call buttons dial a sanitized `tel:` (digits + leading `+`). Remote images load through `RetryableAsyncImage` (SwiftUI) / `RetryableImageView` (UIKit) — a URLSession loader with a placeholder, fallback, and tap-to-retry — so a slow image never blocks the bubble.

*Example:* [`AttachmentCarousel.swift`](Examples/Components/SwiftUI/AttachmentCarousel.swift) · [`AttachmentCarouselView.swift`](Examples/Components/UIKit/AttachmentCarouselView.swift) · [`URLCardView.swift`](Examples/Components/UIKit/URLCardView.swift) · [`CallActionsRow.swift`](Examples/Components/UIKit/CallActionsRow.swift)

### Rich text & links
**Data:** `AgentMessage.text` is Markdown — `**bold**`, `*italic*`, `` `code` ``, `[links](https://…)`.

```swift
// SwiftUI — RichText parses Markdown → AttributedString and opens links via openURL
RichText(m.text)
```
```swift
// UIKit — render into a UITextView (NOT a UILabel) so links are tappable
let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
textView.attributedText = (try? AttributedString(markdown: m.text, options: opts)).map(NSAttributedString.init)
textView.isEditable = false
textView.isScrollEnabled = false   // self-sizes in the cell
```
> `AttributedString(markdown:)` doesn't linkify *bare* URLs — `RichText` adds a regex pass for those and tolerates half-open Markdown from streaming.

*Example:* [`RichText.swift`](Examples/Components/SwiftUI/RichText.swift) · `renderMarkdown` in [`MessageCell.swift`](Examples/Components/UIKit/MessageCell.swift)

### Connection & reconnect
**Data:** `session.connection` — show a banner only while `.reconnecting` (drops go `.open → .reconnecting(n) → .open`, no `.closed` flash). `session.failureReason` is terminal — offer `client.resume()`. Use `isConnected` / `isReconnecting` / `isFailed` (full list under [Connection states](#connection-states)).

```swift
// SwiftUI
if case .reconnecting = session.connection {
    Text("Reconnecting…").font(.caption)
        .frame(maxWidth: .infinity).padding(6).background(.yellow.opacity(0.15))
}
if session.failureReason != nil {
    Button("Try again") { Task { try? await session.client.resume() } }
}
```
```swift
// UIKit
session.$connection
    .receive(on: RunLoop.main)
    .sink { [weak self] status in
        self?.reconnectBanner.isHidden = !status.isReconnecting
        if status.isFailed { self?.showRetry { Task { try? await self?.session.client.resume() } } }
    }
    .store(in: &bag)
```
*Example:* [`ConnectionBanner.swift`](Examples/SwiftUI/02-Standard/Components/ConnectionBanner.swift) · reconnect banner in [`02-Standard ChatViewController.swift`](Examples/UIKit/02-Standard/Views/ChatViewController.swift)

**Device offline is a separate signal.** `session.connection` tracks the *socket*, not whether the *phone* lost Wi-Fi. For that, watch the OS network path with `NWPathMonitor` and show a distinct "You're offline" bar — the examples wrap this as `NetworkMonitor` + `OfflineBanner` (04-Resilience). The two can stack: offline (device) on top, reconnecting (socket) below.

### Live agent handoff
**No special listening** — handoff is already in `messages`: progress as `.system` events (your `systemLabel(_:)` from the core pattern renders them), live-agent replies as `.agent` with `agentKind == .live`, live typing via `isAgentTyping`. Just tint the live agent so the user can tell a human took over.

```swift
// SwiftUI — in your agent bubble
let isLive = m.agentKind == .live
if isLive, let name = m.agentName {
    Text("\(name) · live agent").font(.caption).foregroundStyle(.teal)
}
Text(m.text).padding(10)
    .background(isLive ? Color.teal.opacity(0.18) : Color(.systemGray5))
```
```swift
// UIKit — in your cell
let isLive = (m.agentKind == .live)
bubble.backgroundColor = isLive ? UIColor.systemTeal.withAlphaComponent(0.18) : .systemGray5
nameLabel.text = isLive ? "\(m.agentName ?? "Agent") · live agent" : m.agentName
```
`.liveAgentLeft` is terminal (the SDK flips `hasEnded`). To deep-link a handoff route, observe [`client.events`](#side-effects-clientevents).

*Example:* [`05-Handoff MessageBubbleView.swift`](Examples/SwiftUI/05-Handoff/Components/MessageBubbleView.swift) · [`05-Handoff MessageCell.swift`](Examples/UIKit/05-Handoff/Components/MessageCell.swift)

### Streaming
The agent's reply arrives as a sequence of chunks. `ChatSession` reassembles them for you and updates `messages` — you never touch chunks directly. You only choose **how a reply appears**:

- **Completed (default).** The bubble shows up once, fully formed, when the reply finishes. While the agent writes, `isAgentTyping` is `true` (show the typing dots); then the assembled message simply appears in `messages`.
- **Progressive (opt-in).** The bubble appears immediately and **grows token-by-token** as chunks land (ChatGPT-style), then is replaced in place by the final, fully-formatted message. Turn it on at session creation — **the view code is identical**, the same `messages` array just updates more often:

```swift
// SwiftUI
@StateObject var session = PolyMessaging.chat(progressiveStreaming: true)
```
```swift
// UIKit
session = PolyMessaging.chat(progressiveStreaming: true)
```
(With an explicit config: `PolyMessaging.chat(config, progressiveStreaming: true)`; `start(...)` takes it too.)

Two switches govern streaming, and they're independent:

| Switch | Where | Controls |
|---|---|---|
| `streamingEnabled` | `Configuration` (default `true`) | whether the **server** sends chunks at all |
| `progressiveStreaming` | `chat()` / `start()` (default `false`) | whether `ChatSession` **renders** chunks live vs. waiting for the assembled message |

Leave `streamingEnabled` on and add `progressiveStreaming: true` for live text. With `streamingEnabled: false`, replies arrive whole and `progressiveStreaming` has nothing to animate. Either way, your render code — the `switch` over `messages` from [the core pattern](#the-core-pattern-render-messages-yourself) — doesn't change.

*Example:* [`07-Playground`](Examples/SwiftUI/07-Playground/) · [`07-Playground`](Examples/UIKit/07-Playground/) — both toggle `progressiveStreaming` live so you can feel the difference.

### Loading & empty states
**Data:** `isReady` (false until connected) + `messages.isEmpty`. Show a skeleton until the first messages arrive, then swap to the transcript.

```swift
// SwiftUI
if !session.isReady && session.messages.isEmpty { LoadingSkeleton() }
```
```swift
// UIKit
let showSkeleton = !session.isReady && session.messages.isEmpty
skeleton.isHidden  = !showSkeleton
tableView.isHidden = showSkeleton
```
*Example:* [`LoadingSkeleton.swift`](Examples/Components/SwiftUI/LoadingSkeleton.swift) · [`LoadingSkeleton.swift`](Examples/Components/UIKit/LoadingSkeleton.swift)

### Terminal errors
**Data:** `session.failureReason` (non-nil once auto-reconnect is exhausted — the one state that needs the user). `PolyError` isn't `LocalizedError`, so use `String(describing: reason)`, not `.localizedDescription`.

```swift
// SwiftUI — full-screen error + retry
if let reason = session.failureReason {
    VStack(spacing: 12) {
        Text("Connection lost").font(.headline)
        Text(String(describing: reason)).foregroundStyle(.secondary)
        Button("Try again") { Task { try? await session.client.resume() } }
    }
}
```
```swift
// UIKit
session.$failureReason
    .receive(on: RunLoop.main)
    .sink { [weak self] reason in
        self?.errorView.isHidden = (reason == nil)
        self?.errorLabel.text = reason.map { String(describing: $0) }
    }
    .store(in: &bag)
// retry button → Task { try? await session.client.resume() }
```
*Example:* [`ErrorScreen.swift`](Examples/SwiftUI/06-FullReference/Views/ErrorScreen.swift) · [`ErrorViewController.swift`](Examples/UIKit/06-FullReference/Views/ErrorViewController.swift)

### Message timestamps
**Data:** `ChatMessage.timestamp` (also on each `UserMessage` / `AgentMessage` / `SystemMessage`).

```swift
// SwiftUI
Text(message.timestamp, style: .time)               // e.g. "3:42 PM"
    .font(.caption2).foregroundStyle(.secondary)
```
```swift
// UIKit
let f = DateFormatter(); f.timeStyle = .short
timeLabel.text = f.string(from: message.timestamp)
```
For a date-grouped separator row, see the examples' `MessageTimestamp` + `TimestampSeparator`.

*Example:* [`TimestampSeparator.swift`](Examples/SwiftUI/07-Playground/Components/TimestampSeparator.swift) · [`MessageTimestamp.swift`](Examples/UIKit/07-Playground/Helpers/MessageTimestamp.swift)

### Avatars & keyboard
**Data:** `agentAvatarUrl` (latest) and `AgentMessage.avatarUrl` (per-message). Keyboard handling is yours.

```swift
// SwiftUI — avatar + interactive keyboard dismiss
AgentAvatarView(url: m.avatarUrl)
ScrollView { /* messages */ }.scrollDismissesKeyboard(.interactively)   // iOS 16+
```
```swift
// UIKit — load the avatar with the retryable image view; ride the keyboard
avatarView.load(url: m.avatarUrl)
inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
```
*Example:* [`AgentAvatarView.swift`](Examples/SwiftUI/05-Handoff/Components/AgentAvatarView.swift) · [`RetryableImageView.swift`](Examples/Components/UIKit/RetryableImageView.swift) · [`InteractiveKeyboardDismiss.swift`](Examples/Components/SwiftUI/Helpers/InteractiveKeyboardDismiss.swift)

## Side effects: `client.events`

Rendering reads `messages`. For **imperative reactions** — navigate, play a haptic, log analytics — observe the typed event stream instead. (This is the lower-level API `ChatSession` is built on; reach for it only for side effects.)

```swift
for await event in session.client.events {
    switch event {
    case .liveAgentJoined(_, let agent):
        haptics.success(); analytics.track("handoff", agent.agentName)
    case .clientHandoffRequired(_, let payload):
        if let route = payload.route, let url = URL(string: route) { UIApplication.shared.open(url) }
    case .sessionEnd:
        analytics.track("chat_ended")
    default:
        break
    }
}
```

> Tie the `Task` to your view's lifecycle (SwiftUI `.task { }`, or cancel in `deinit`). Subscribe **before** sending — `events` is lazy-start.

---

# Reference

## Configuration

```swift
PolyMessaging.initialize(.init(
    connectorToken: "your_token",
    environment: .cluster("us-1")
))
```

`environment` is required; everything else has a working default.

| Field | Default | Description |
|---|---|---|
| `connectorToken` | — (required) | Auth token from Agent Studio. Treat as a credential — never log it. |
| `environment` | — (required) | API + WebSocket endpoints (see below) |
| `hostIdentifier` | Bundle ID | `X-Host` for connector validation; auto-derived from `Bundle.main.bundleIdentifier` |
| `streamingEnabled` | `true` | `true`: server streams chunks. `false`: complete messages only |
| `greetingMessage` | `nil` | Custom welcome message shown when the agent joins (overrides the agent's default) |
| `logLevel` | `.error` | `.none` \| `.error` \| `.warn` \| `.info` \| `.debug` |
| `heartbeatIntervalSeconds` | `nil` (30 s) | Override the heartbeat interval; server caps may overrule |
| `sessionTimeoutSeconds` | `nil` (3600) | Override the idle-timeout |
| `maxReconnectAttempts` | `nil` (10) | Override the reconnect cap |

> `streamingEnabled` controls whether the **server** streams chunks; `progressiveStreaming` (a parameter on `chat()` / `start()`, not a `Configuration` field) controls whether `ChatSession` renders them live.

**Environments:** `.production` (`messaging.poly.ai`) · `.cluster("us-1")` (`messaging.us-1.poly.ai`, also `uk-1`, `euw-1`, …) · `.staging` · `.dev` · `.custom(restBaseURL:, wsBaseURL:)`.

A fully-specified configuration (every value here has a working default — set only what you need to override):

```swift
PolyMessaging.initialize(.init(
    connectorToken: "your_token",
    environment: .cluster("us-1"),
    hostIdentifier: "com.yourapp.ios",       // X-Host for connector validation; defaults to your bundle id
    streamingEnabled: true,                  // server streams agent replies as chunks
    greetingMessage: "Hi! How can I help?",  // overrides the agent's default welcome message
    logLevel: .error,                        // .none | .error | .warn | .info | .debug
    heartbeatIntervalSeconds: 30,            // server caps may overrule
    sessionTimeoutSeconds: 3600,             // idle timeout before the session expires
    maxReconnectAttempts: 10                 // reconnect budget before .failed
))
```

## Error handling

`send()` / `end()` throw `PolyError`. Use the convenience flags, or pattern-match the nested cases:

```swift
do {
    try await session.send(text)
} catch let error as PolyError {
    if error.isAuthError            { showError("Authentication failed") }
    else if error.isSessionExpired  { showError("Session timed out — start a new chat") }
    else if error.isRetryable       { showError("Connection issue — retrying…") }
    else                            { showError("Something went wrong: \(error)") }
}

switch error {
case .auth(.unauthorized):                  showError("Invalid connector token")
case .session(.sessionExpired):             showError("Session timed out")
case .transport(.networkError(let reason)): showError("Network: \(reason)")
default:                                     showError("\(error)")
}
```

Every case `PolyError` can throw, and when:

| Case | Fires when | Retryable |
|---|---|---|
| `.auth(.tokenAcquisitionFailed)` | the access-token request failed | no |
| `.auth(.unauthorized)` | the connector token was rejected (401/403) | no |
| `.session(.sessionCreationFailed(code))` | the server refused to create a session (`code` says why) | no |
| `.session(.unexpectedDisconnect(code:reason:))` | the socket dropped unexpectedly | yes |
| `.session(.maxReconnectAttemptsExceeded)` | reconnects were exhausted (terminal — offer `resume()`) | yes |
| `.session(.sessionExpired)` | the session idled out | no |
| `.session(.sessionEnded(reason:))` | the conversation ended | no |
| `.message(.deliveryFailed(draftId:))` | a sent message never confirmed after retries | no |
| `.message(.payloadTooLarge(maxBytes:))` | the message exceeds `max_message_size_bytes` | no |
| `.transport(.networkError(_))` · `.transport(.protocolError(reason:))` | a network / protocol-level failure | yes |
| `.invalidConfiguration(_)` | bad `Configuration` (e.g. empty token) | no |

Convenience flags: `isAuthError`, `isSessionError`, `isTransportError`, `isSessionExpired`, `isRetryable`.

## Connection states

`session.connection` is a `ConnectionStatus`. You rarely match it directly — `isConnected` / `isReconnecting` / `isFailed` / `isActive` and `session.failureReason` cover most UIs — but the full set:

| State | Meaning |
|---|---|
| `.idle` | not started yet |
| `.connecting` | opening the socket |
| `.open` | connected and ready (`isConnected`) |
| `.reconnecting(attempt:)` | transient drop; auto-retrying (`isReconnecting`) — show a banner |
| `.closing` | shutting down |
| `.closed(_)` | the server cleanly ended the session |
| `.failed(reason:)` | reconnect budget exhausted (`isFailed`) — offer manual `client.resume()` |

## Testing

Three scenarios catch most real-world breakage:

| Scenario | What it exercises |
|---|---|
| Toggle airplane mode mid-chat, then back | fast disconnect → `.reconnecting` → auto-resume on restore |
| Background the app > 5 min, then foreground | idle-timeout vs reconnect-and-resume paths |
| Kill and relaunch within the session timeout | `chat()` restores the conversation; `start()` always starts fresh |

## How it works

The SDK implements the [PolyAI Messaging API](https://polyai-docs-messaging-api.mintlify.app/api-reference/messaging/introduction) — a WebSocket protocol — and manages the whole lifecycle: access-token → session → WebSocket → `REQUEST_POLY_AGENT_JOIN` → event exchange, with heartbeat, dedup, and cursor-based replay handled internally.

**Two consumer layers on one orchestrator. Both work in SwiftUI and UIKit** (`ChatSession`'s `@Published` properties are Combine, which UIKit consumes via `sink` — the only difference is the binding):

```
Your App (SwiftUI or UIKit)
  └─ ChatSession (ObservableObject)         ← observe @Published state; recommended
       └─ PolyMessagingClient                ← raw AsyncStream events; build your own state machine
            └─ Coordinator (actor)           ← SessionService · ChatService · ConnectionService
                                                HeartbeatService · NetworkMonitor
```

| Layer | When to use |
|---|---|
| `ChatSession` | **Recommended, both frameworks.** Observe `@Published` state; the SDK handles streaming assembly, dedup, delivery, resets. |
| `PolyMessagingClient` | Drive the raw `events` / `connectionStatus` / `sessionState` streams and build your own state. |
| `getConnection()` | Escape hatch — raw WebSocket frames. See [Raw transport](#advanced-raw-transport). |

**Reconnection is automatic:** drops the dead socket within ~100 ms of the OS reporting offline; exponential backoff with ±20% jitter (1s → 2s → … → 30s cap); transparent reconnect at the 2-hour mark and on session expiry; resumes from the last sequence (`cursor=<n>`) and dedups replayed events by `id`. When the reconnect budget is exhausted, `connection` becomes `.failed` — offer `client.resume()`.

**Design:** zero dependencies (Apple frameworks only); actor-based concurrency; hexagonal — transports and persistence behind protocols, so every layer is testable in isolation.

## Advanced: raw transport

`getConnection()` returns the live `Connection` for custom analytics or proprietary event types:

```swift
let raw = session.client.getConnection()

await raw.send(.userMessage(text: "Hello"))   // typed OutgoingEvent — SDK encodes JSON
await raw.send(.heartbeat)
await raw.sendRaw(Data(#"{"type":"EVENT_TYPE_CUSTOM"}"#.utf8))   // arbitrary frame

Task { for await frame in raw.rawFrames { analytics.record(frame) } }   // tap every frame
```

`send(_:)` (typed `OutgoingEvent`), `sendRaw(_:)` (arbitrary JSON), `rawFrames` / `messages` (`AsyncStream`s), `openEvents` / `closeEvents`.

> `sendRaw` bypasses delivery tracking, retry, and `local_id` correlation — no `.messagePending` / `.messageConfirmed`. Use it only when the managed `client.send(_:)` path doesn't fit.

## Dev tools (QA)

For internal builds, `DevSettings` (a public `ObservableObject`) is a UserDefaults-backed runtime `Configuration` builder — flip environment, streaming, logging, and other knobs without rebuilding. The **07-Playground** example pairs it with an on-screen diagnostics strip and event log, plus the [raw transport](#advanced-raw-transport) tap for protocol-level pokes. These are for development/QA — they bake in no credentials and aren't needed in production.

## Example apps

A progressive ladder, mirrored across SwiftUI and UIKit — open any `.xcodeproj` and Cmd+R (pre-wired against the dev environment). The components used throughout live in [`Examples/Components/`](Examples/Components/).

| Level | What it adds | SwiftUI · UIKit |
|---|---|---|
| **01 Hello** | initialize, render, send | [SwiftUI](Examples/SwiftUI/01-Hello/) · [UIKit](Examples/UIKit/01-Hello/) |
| **02 Standard** | typing, suggestions, delivery, reconnect, end + start-new | [SwiftUI](Examples/SwiftUI/02-Standard/) · [UIKit](Examples/UIKit/02-Standard/) |
| **03 Rich Content** | attachments, link cards, `tel:` actions, Markdown | [SwiftUI](Examples/SwiftUI/03-RichContent/) · [UIKit](Examples/UIKit/03-RichContent/) |
| **04 Resilience** | offline banner, loading skeleton, terminal error + retry | [SwiftUI](Examples/SwiftUI/04-Resilience/) · [UIKit](Examples/UIKit/04-Resilience/) |
| **05 Handoff** | full live-agent ladder | [SwiftUI](Examples/SwiftUI/05-Handoff/) · [UIKit](Examples/UIKit/05-Handoff/) |
| **06 Full reference** | production resume + start-new flows | [SwiftUI](Examples/SwiftUI/06-FullReference/) · [UIKit](Examples/UIKit/06-FullReference/) |
| **07 Playground** | diagnostics, runtime config, streaming toggle | [SwiftUI](Examples/SwiftUI/07-Playground/) · [UIKit](Examples/UIKit/07-Playground/) |

The example apps under `Examples/` are provided as copy-paste starting points — lift any view straight into your app; every component takes only public SDK types (`ChatMessage`, `Attachment`, `ResponseSuggestion`, `ChatCallAction`, `ConnectionStatus`), no internals.

## Requirements

| | Minimum |
|---|---|
| iOS | 15.0+ |
| Swift | 5.9+ |
| Xcode | 15.0+ |
| Dependencies | None — Apple frameworks only |

## License

Copyright © PolyAI. All rights reserved.
