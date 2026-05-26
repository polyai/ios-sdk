# 02-Standard (UIKit)

The 80% chat, in UIKit. Adds typing indicator, connection banner, suggestion pills, delivery state (Sending… + failed retry), end + start new chat, and a failure overlay on top of [`01-Hello`](../01-Hello/). The UIKit counterpart of [`../../SwiftUI/02-Standard/`](../../SwiftUI/02-Standard/).

- **Interface:** Storyboard (`Resources/Main.storyboard`)
- **Lifecycle:** `AppDelegate` (`@main`) + `SceneDelegate` (scene-based)

Setup and `send()` are unchanged from [`01-Hello`](../01-Hello/) — read it first. This README only covers what's new.

## Run it

```bash
open StandardUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Connector token + dev environment are pre-filled in `App/AppDelegate.swift`.

## New in this level

- `Components/MessageCell.swift` — message bubble cell; renders delivery state (Sending… / failed + tap-to-retry).
- `Components/SuggestionsView.swift` — horizontal quick-reply pills.

`Views/ChatViewController.swift` is rebuilt from 01's into the full chat surface every later level extends. Setup (`AppDelegate`, `SceneDelegate`) is inherited from [`01-Hello`](../01-Hello/).

The Storyboard intentionally only wires the navigation controller, `ChatViewController`, and the End `UIBarButtonItem` (outlet + action). Every other view — table, banner, input bar, suggestions, failure overlay — is built programmatically in `viewDidLoad`, keeping the Storyboard XML small.

## How it works

### Typing indicator — `Views/ChatViewController.swift`

**Under the hood:** `isAgentTyping` is SDK-managed — true while the agent composes (driven by its thinking/streaming signals), auto-cleared on the next agent message or after the typing timeout (~10s), so you never run a timer. `sendTyping()` throttles outgoing STARTED to ≤1 per 3s and auto-emits STOPPED ~5s after your last call, so it's safe to fire on every keystroke.

The SDK throttles STARTED frames to ≤1/3s, so it's safe to call on every keystroke.

```swift
inputField.addAction(UIAction { [weak self] _ in
    Task { await self?.session.sendTyping() }
}, for: .editingChanged)

session.$isAgentTyping
    .receive(on: RunLoop.main)
    .sink { [weak self] typing in self?.setTypingIndicatorVisible(typing) }
    .store(in: &bag)
```

*See [Build your own UI › Typing](../../../README.md#typing).*

### Connection banner — `Views/ChatViewController.swift`

**Under the hood:** `session.connection` is SDK-driven — a transient drop surfaces as `.open → .reconnecting(n) → .open` (auto-reconnect with backoff and jitter, no `.closed` flash), so you only need to react to `.reconnecting`. `.failed` arrives only after the reconnect budget is exhausted.

Only shown during reconnects. There is no attempt counter — `ConnectionStatus.reconnecting` carries an attempt number, but this example just shows a spinner + label.

```swift
session.$connection
    .receive(on: RunLoop.main)
    .sink { [weak self] status in
        if case .reconnecting = status {
            self?.connectionBanner.isHidden = false
            self?.connectionSpinner.startAnimating()
        } else {
            self?.connectionBanner.isHidden = true
            self?.connectionSpinner.stopAnimating()
        }
    }
    .store(in: &bag)
```

*See [Build your own UI › Connection & reconnect](../../../README.md#connection--reconnect).*

### Suggestion pills — `Components/SuggestionsView.swift`

**Under the hood:** `AgentMessage.suggestions` are quick replies the agent attached to *that* message (agent messages only); `clearSuggestions(for:)` empties them in the model so the pills vanish. Show them only on the latest agent message.

Pills render **under the last agent message** as their own table row
(`SuggestionsCell`, which hosts `SuggestionsView`), so they sit with the reply that
offered them and scroll with the conversation. `render(_:)` appends a `.suggestions`
row after the last message while it carries suggestions and the chat is live;
sending clears it (the user's message becomes last). Tapping a pill clears the
suggestion locally, then sends its text.

```swift
// In the diffable data source, the suggestions row hosts the pills:
case .suggestions(let id):
    let cell = tableView.dequeueReusableCell(withIdentifier: SuggestionsCell.reuseID,
                                             for: indexPath) as! SuggestionsCell
    if let message = self.session.messages.first(where: { $0.id == id }) {
        cell.configure(suggestions: message.suggestions) { [weak self] suggestion in
            self?.session.clearSuggestions(for: id)
            Task { try? await self?.session.send(suggestion.messageText) }
        }
    }
    return cell
```

*See [Build your own UI › Suggestions](../../../README.md#suggestions-quick-replies).*

### End + Start new chat — `Views/ChatViewController.swift`

**Under the hood:** `ChatSession` is `@MainActor`, so its `@Published` props update on the main thread — sink them straight onto your views. `startNewSession()` creates a fresh session and, when the session id changes, `ChatSession` clears `messages` and resets the latched flags for you.

`session.end()` flips `hasEnded`; the binding swaps the input bar for a "chat ended" footer with a Start New Chat button.

```swift
@IBAction func endTapped(_ sender: Any) {
    Task { try? await session.end() }
}

@objc private func startNewChatTapped() {
    Task { try? await session.client.startNewSession() }
}
```

`Publishers.CombineLatest(session.$isReady, session.$hasEnded)` swaps `inputBar` for `chatEndedView` and removes the End bar-button when the chat ends. `startNewSession()` resets `messages`/`hasEnded` on the session-id change.

*See [Build your own UI › Starting, resuming & ending a session](../../../README.md#starting-resuming--ending-a-session).*

### Delivery state + retry — `Components/MessageCell.swift`

**Under the hood:** `UserMessage.delivery` is optimistic — `.pending` immediately, then the SDK matches the server echo (via a local id) → `.sent`; if no echo arrives it retries (up to 3×) then settles on `.failed`. You only render it; `removeMessage(draftId:)` drops a failed draft so a retry doesn't leave a duplicate.

`configure(with:onRetry:showSendingLabel:)` renders the user message's `delivery` state: `showSendingLabel` shows "Sending…" for `.pending`, and a `.failed` message gets a tap-to-retry control that re-sends its text.

```swift
let pending: Bool
if case .user(let m) = message, m.delivery == .pending { pending = true } else { pending = false }
cell.configure(
    with: message,
    onRetry: { [weak self] text in Task { try? await self?.session.send(text) } },
    showSendingLabel: pending
)
```

*See [Build your own UI › Delivery state & retry](../../../README.md#delivery-state--retry).*

### Failure overlay — `Views/ChatViewController.swift`

**Under the hood:** `session.connection` reaches `.failed` only after the SDK's auto-reconnect budget is exhausted; `failureReason` then holds the terminal error. Recovery is consumer-driven — call `client.resume()` to restart the connection.

When the SDK gives up reconnecting, `failureReason` is set; offer a manual retry.

```swift
session.$failureReason
    .receive(on: RunLoop.main)
    .sink { [weak self] reason in
        self?.failureOverlay.isHidden = (reason == nil)
        // PolyError isn't LocalizedError — use String(describing:) so the
        // label reflects the actual case instead of Error's generic default.
        self?.failureLabel.text = reason.map { String(describing: $0) }
    }
    .store(in: &bag)

@objc private func reconnectTapped() {
    Task { try? await session.client.resume() }
}
```

*See [Build your own UI › Connection & reconnect](../../../README.md#connection--reconnect).*

### Keyboard handling — `Views/ChatViewController.swift`

The input bar is pinned to `view.keyboardLayoutGuide.topAnchor`, so it rides the keyboard up and down with no notification observers; `tableView.keyboardDismissMode = .interactive` lets a downward scroll dismiss it.

```swift
inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
tableView.keyboardDismissMode = .interactive
```

*See [Build your own UI › Avatars & keyboard](../../../README.md#avatars--keyboard).*

## Storyboard note

`Main.storyboard` hard-codes `customModule="StandardUIKit"` on the view controller. If you rename the Xcode target, update the **Module** field in the Identity Inspector to match — or set it to "None".

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

SwiftUI counterpart: [`Examples/SwiftUI/02-Standard/`](../../SwiftUI/02-Standard/). When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** that counterpart. See `SKILL.md §12`.
