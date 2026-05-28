# PolyMessaging iOS SDK — Agent Brief

Brief for AI coding agents helping a developer **integrate this SDK into their app**.
Humans should start with [`README.md`](../README.md) (a step-by-step guide).

## What this package is

- A dependency-free Swift Package (iOS 15+, macOS 12+, Swift 5.9+) — Apple frameworks only.
- Adds AI-agent chat to an app. The SDK manages token auth, the WebSocket, streaming,
  reconnection, delivery tracking, and live-agent handoff. **The developer builds the UI
  and binds to `ChatSession`.**

## Recommended integration path (use this unless the user asks otherwise)

1. **Initialize once at app launch** (SwiftUI `App.init` / UIKit `AppDelegate`):
   `PolyMessaging.initialize(.init(apiKey: "…", environment: .cluster("us-1")))`
2. **Create one `ChatSession` per chat surface** — `let session = PolyMessaging.chat()`.
   It's a `@MainActor ObservableObject`. Don't recreate it per view render.
3. **Bind its published state:** `messages`, `isAgentTyping`, `connection`, `isReady`,
   `hasEnded`, `failureReason`, `agentAvatarUrl`.
   - SwiftUI: `@StateObject var session = PolyMessaging.chat()`.
   - UIKit: sink the `@Published` props via Combine (`session.$messages.sink { … }`).
4. **Send / teardown:** `try await session.send(text)`; `await session.client.shutdown()`
   when the surface goes away for good.

The agent joins and greets automatically. Full walkthrough: README **Step 1**.

## Where to find things (prefer copying over inventing)

- [`README.md`](README.md) — canonical step-by-step guide (Steps 1–6) + Configuration,
  Error handling, Raw transport. **Mirror its snippets; don't contradict them.**
- `Examples/SwiftUI/<NN-Name>/` and `Examples/UIKit/<NN-Name>/` — runnable apps, one per
  capability: `01-Hello … 07-Playground`. `06-FullReference` is the most complete.
- When implementing a feature for the user, **copy the matching component from
  `Examples/SwiftUI/06-FullReference/Components/` or
  `Examples/UIKit/06-FullReference/Components/`** (and adapt) rather than writing it
  from scratch — those folders are the production-shaped versions of every view
  component (message bubbles, attachment carousel, suggestion pills, typing dots,
  rich text, URL cards, retryable images, banners) and use **only public SDK types**.

## Public API you'll use (don't invent surface — check `Sources/PolyMessaging/Public/`)

- **Facade:** `PolyMessaging.initialize(_:)`, `.chat(streamingEnabled:)`,
  `.start(streamingEnabled:)`, `.configure(_:)` (lower-level), `.hasResumableSession()`,
  `.clearResumableSession()`. The `streamingEnabled:` parameter is an optional
  per-session override of `Configuration.streamingEnabled`.
- **`ChatSession`:** state `messages`/`isAgentTyping`/`connection`/`isReady`/`hasEnded`/
  `failureReason`/`agentAvatarUrl`; actions `send(_:)`/`sendTyping()`/`end()`/
  `clearSuggestions(for:)`/`clearChat()`; plus `client` (the lower-level `PolyMessagingClient`).
- **`ChatMessage`** enum (`.user/.agent/.system`, `Identifiable`) with `text`,
  `delivery`, `suggestions`, `attachments`.
- **`Configuration`:** `apiKey` (required), `environment` (required),
  `streamingEnabled`, `logLevel`, `sessionTimeoutSeconds`,
  `heartbeatIntervalSeconds`, `maxReconnectAttempts`.
- **`Environment`:** `.production`, `.cluster("us-1")`,
  `.custom(restBaseURL:wsBaseURL:)`.

## Hard rules (real gotchas — follow these)

- **Prefer `ChatSession` over raw `client.events`.** It assembles streaming chunks,
  tracks delivery, manages the typing indicator, and dedupes on resume. Only drop to
  `client.events` for behavior `ChatSession` doesn't cover.
- **Subscribe before sending** — `client.events` is lazy-start (the first subscriber
  opens the connection). `ChatSession` handles this for you.
- **Lifecycle:** initialize **once** (not per view); **one** `ChatSession` per surface;
  `await session.client.shutdown()` on teardown (idempotent).
- **UIKit links:** render agent text in a non-editable **`UITextView`, not a `UILabel`**
  — a label styles Markdown links but won't make them tappable. SwiftUI `Text` handles it.
- **Agent text is Markdown, not HTML** — parse and render it (bold/italic/links); there's
  nothing to sanitize. See README "Rich text & links".
- **Don't render `.agentMessageChunk` as a bubble.** Render the assembled `.agentMessage`;
  chunks only keep the typing indicator alive (when `streamingEnabled: false`). With
  `streamingEnabled: true` (default), `ChatSession` does the live token-by-token
  rendering for you.
- **Suggestion pills** render under the last agent message and clear when the user sends
  (see the example `ChatViewController` / `MessageBubbleView`).
- **Never log the API key.**

## Verifying changes

- SDK: `swift build`, `swift test`.
- All example apps: `scripts/build-all.sh`.
- A single example (uses [xcodegen](https://github.com/yonaskolb/XcodeGen)):
  `cd Examples/SwiftUI/06-FullReference && xcodegen generate && open *.xcodeproj`.

## Scope boundaries

- **Don't add third-party dependencies** — this package is intentionally dependency-free.
- When integrating into an app, **consume the public API**; don't edit
  `Sources/PolyMessaging/` to make integration "easier."
- Keep credentials out of source — set the API key via `initialize(...)`.
