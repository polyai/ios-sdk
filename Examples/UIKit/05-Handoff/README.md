# 05-Handoff (UIKit)

Live-agent handoff on top of [`04-Resilience`](../04-Resilience/). Queue / accept / fail / agent-joined events become centered system pills in the transcript; live-agent bubbles get distinct styling.

- **Interface:** Storyboard (`Main.storyboard`) plus programmatic banners/overlays.
- **Lifecycle:** `AppDelegate` (`@main`) + `SceneDelegate`.

## Run it

```bash
open HandoffUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your API key in `AppDelegate.swift` (currently `"YOUR_API_KEY"`).

## What this example demonstrates

- Render handoff progress (queue / accept / fail / timeout) as centered `.system` pill cells
- Tint a live-agent `MessageCell` teal and tag the caption with `· live agent`
- Subscribe to raw `client.events` via a `for await` task for app side effects
- Reuse `session.$isAgentTyping` for live-agent typing — no new flag needed
- Let `.liveAgentLeft` flip `session.hasEnded` naturally so the existing chat-ended footer takes over

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them as one concrete view controller.

## How it works

Each subsection leads with **the SDK call** (one or a few lines — the actual API), then shows **how it's wired into a view controller**.

### Handoff status pills — `Components/MessageCell.swift`

Match what `02-Standard` already does for `.system` rows: render every handoff transition as a centered chat pill, not a header banner. `ChatSession` does the heavy lifting — you just switch on the system event:

The SDK signal:

```swift
session.messages                  // includes .system messages for every handoff transition

// SystemEvent cases you'll typically handle:
// .liveAgentJoined(name)         // a human agent picked up
// .queueStatus(position, displayMessage)
// .handoffStarted
// .handoffAccepted
// .handoffFailed(reason)
// .handoffTimeout
// .liveAgentLeft                 // terminal — hasEnded follows
```

In a cell (system branch):

```swift
private func systemText(for event: SystemEvent) -> String {
    switch event {
    case .liveAgentJoined(let name): return "\(name ?? "An agent") joined"
    case .queueStatus(let position, let displayMessage):
        if let displayMessage, !displayMessage.isEmpty { return displayMessage }
        return position.map { "Position #\($0) in queue" } ?? "Queued..."
    case .handoffStarted:  return "Transferring to a live agent..."
    case .handoffAccepted: return "An agent will be with you shortly"
    case .handoffFailed(let reason):
        return reason.map { "Transfer failed: \($0)" } ?? "Transfer failed"
    case .handoffTimeout:  return "No agents available"
    default:               return "This conversation has ended"
    }
}

// The system pill reuses the cell's existing `label` (a UITextView/UILabel inside `bubble`) —
// no separate pillLabel/pillContainer subviews. configureSystem just swaps colors + corner radius
// and activates the `centerConstraint` so the bubble sits centered in the cell.
private func configureSystem(_ m: SystemMessage) {
    label.text = systemText(for: m.event)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabel
    bubble.backgroundColor = .systemGray6
    bubble.layer.cornerRadius = 14
    centerConstraint.isActive = true   // center-pin the outer stack; leading/trailing constraints stay off
}
```

**Under the hood:** the SDK converts every handoff transition — agent-triggered handoff, queue status, accepted / failed / timeout, live-agent joined / left — into a `.system` message appended to `session.messages`. They interleave with `.user` / `.agent` bubbles in the timeline, so you only render the `.system` branch and the order comes out right for free.

*See [Integration guide › Agent handoff](../../../README.md#agent-handoff).*

### Live-agent bubble styling — `Components/MessageCell.swift`

Live-agent replies are ordinary `.agent` messages — the same rendering path as Poly agent replies. Switch on `AgentMessage.agentKind` to tint them and tag the caption:

The SDK signal:

```swift
AgentMessage.agentKind   // .poly (default) or .live — live = a human handled by handoff
AgentMessage.agentName   // optional display name (used for the caption)
```

In a cell (agent branch):

```swift
private func configureAgent(_ m: AgentMessage) {
    let isLive = (m.agentKind == .live)

    avatarView.isHidden = false
    avatarView.load(url: m.avatarUrl, fallback: UIImage(systemName: "person.circle.fill"))
    if isLive {
        avatarView.layer.borderWidth = 1.5
        avatarView.layer.borderColor = UIColor.systemTeal.cgColor   // teal ring for live agents
    }

    if let name = m.agentName, !name.isEmpty {
        captionLabel.isHidden = false
        if isLive {
            // "<name> · live agent", with the " · live agent" suffix tinted teal.
            let full = "\(name) · live agent"
            let attr = NSMutableAttributedString(string: full,
                attributes: [.foregroundColor: UIColor.secondaryLabel,
                             .font: UIFont.systemFont(ofSize: 11, weight: .medium)])
            if let range = full.range(of: " · live agent") {
                attr.addAttribute(.foregroundColor, value: UIColor.systemTeal,
                                  range: NSRange(range, in: full))
            }
            captionLabel.attributedText = attr
        } else {
            captionLabel.attributedText = nil
            captionLabel.text = name
            captionLabel.textColor = .secondaryLabel
        }
    }

    bubbleView.backgroundColor = isLive
        ? UIColor.systemTeal.withAlphaComponent(0.18)
        : .systemGray5
    // ...text (UITextView), attachments, URL cards, call actions...
}
```

**Under the hood:** the SDK normalises live-agent replies into the same `AgentMessage` shape as Poly replies — only `agentKind` and (usually) `avatarUrl` / `agentName` differ. Live-agent typing reuses `session.$isAgentTyping`, so the typing indicator works during handoff with no extra wiring.

> **Streaming:** agent replies grow token-by-token by default (`Configuration.streamingEnabled: true` — ChatGPT-style). Live-agent messages flow through the same path, so streaming works for them too. See the root README's [*Streaming*](../../../README.md#streaming) section and [`07-Playground`](../07-Playground/) for a live toggle.

> Reminder from `03-RichContent`: render agent text in a non-editable **`UITextView`**, not a `UILabel` — a label styles Markdown links but ignores taps.

*See [Integration guide › Agent handoff](../../../README.md#agent-handoff).*

### Side effects via raw `client.events` — `Views/ChatViewController.swift`

Rendering reads `session.messages`; raw events are only needed for app-side effects like updating the nav title or deep-linking a route the backend hands you:

The SDK signal:

```swift
session.client.events   // AsyncStream<MessagingEvent> — the raw, decoded stream

// Events you'll typically act on in handoff:
// .liveAgentJoined(_, payload)        // update title / show banner
// .clientHandoffRequired(_, payload)  // deep-link payload.route (the agent told you to)
// .liveAgentLeft                      // clear the title (hasEnded does the rest)
// .sessionStart                       // fresh session → reset title
```

In a view controller:

```swift
final class ChatViewController: UIViewController {
    private var session: ChatSession!
    /// Cancelled in `deinit` so the for-await loop exits when we go away.
    private var eventTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        session = PolyMessaging.chat()
        // ...layoutUI(); configureDataSource(); bind()...
        startEventTask()
    }

    deinit { eventTask?.cancel() }

    private func startEventTask() {
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.session.client.events {
                self.handle(event: event)
            }
        }
    }

    private func handle(event: MessagingEvent) {
        switch event {
        case .liveAgentJoined(_, let p):
            title = (p.agentName?.isEmpty == false) ? p.agentName : "Chat"
        case .clientHandoffRequired(_, let p):
            // Optionally deep-link to the route URL if it parses as http(s).
            if let route = p.route, let url = URL(string: route),
               let scheme = url.scheme, scheme.hasPrefix("http") {
                UIApplication.shared.open(url)
            }
        case .liveAgentLeft, .sessionStart:
            title = "Chat"
        default:
            // Handoff progress flows through session.messages as SystemMessage
            // pills (rendered above). $isAgentTyping covers live-agent typing.
            // .liveAgentMessage flows into session.messages as an AgentMessage
            // with agentKind == .live.
            break
        }
    }
}
```

**Under the hood:** `client.events` is the same typed, decoded stream the SDK uses internally — subscribing adds no transport overhead, and is the right place for imperative side effects (nav title, analytics, deep-linking) that aren't a function of `messages`. Anything renderable already comes through `session.$messages` / `session.$isAgentTyping`, so don't drive the table off this stream.

*See [Integration guide › Agent handoff](../../../README.md#agent-handoff).*

### Why `liveAgentLeft` needs no special handling

It's terminal — `session.hasEnded` flips true and the existing chat-ended footer takes over. The title returns to "Chat" (handled in `.liveAgentLeft` above) so a stale agent name doesn't linger into the next conversation.

**Under the hood:** `.liveAgentLeft` is a terminal transition — the SDK itself flips `hasEnded`, so no app-side bookkeeping is needed to close out the conversation.

## What this example skips

- production-style resume / start-new flow with a dedicated connect screen → [`06-FullReference/`](../06-FullReference/)
- runtime configuration, raw transport experiments, diagnostics → [`07-Playground/`](../07-Playground/)

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/05-Handoff/`](../../SwiftUI/05-Handoff/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
