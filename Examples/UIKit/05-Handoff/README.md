# 05-Handoff (UIKit)

The full live-agent handoff ladder on top of [`04-Resilience`](../04-Resilience/).
Handoff progress renders as centered chat pills, matching L2, while live-agent
bubbles get distinct styling.

## Run it

```bash
open HandoffUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## New in this level

**No new files.** Every file is inherited verbatim from [`04-Resilience`](../04-Resilience/) — handoff is entirely a matter of handling events the SDK already surfaces. The new logic lives in two files that gain code:

- `ChatViewController.swift` — subscribes to raw `MessagingEvent`s for app side effects (set title on `liveAgentJoined`, open the `clientHandoffRequired` route).
- `MessageCell.swift` — renders handoff/queue progress as centered system pills and styles live-agent bubbles (`agentKind == .live`).

`ChatSession` already turns queue/accept/fail events into `SystemMessage` rows — that needs no app code.

## How it works

### Subscribe to raw events — `ChatViewController.swift`

`ChatSession` already turns handoff progress into `SystemMessage` rows in
`session.messages`. The raw event subscription only handles app side effects:
setting the navigation title when a live agent joins and opening a client
handoff route when the backend asks for one.

**Under the hood:** the raw `client.events` stream is only needed for imperative side effects like deep-linking a `clientHandoffRequired` route or analytics — rendering reads `session.messages`, never this stream.

```swift
private func handle(event: MessagingEvent) {
    switch event {
    case .liveAgentJoined(_, let p):
        title = (p.agentName?.isEmpty == false) ? p.agentName : "Chat"
    case .clientHandoffRequired(_, let p):
        if let route = p.route, let url = URL(string: route),
           let scheme = url.scheme, scheme.hasPrefix("http") {
            UIApplication.shared.open(url)
        }
    case .liveAgentLeft:
        title = "Chat"
    case .sessionStart:
        title = "Chat"
    default:
        break
    }
}
```

*See [Build your own UI › Side effects: `client.events`](../../../README.md#side-effects-clientevents).*

### Handoff status pills — `MessageCell.swift`

The pill style is the same pattern used in L2: centered, compact, and part of
the chat transcript rather than a header banner.

**Under the hood:** the SDK converts every handoff transition — agent-triggered handoff, queue status, accepted/failed/timeout, live-agent joined/left — into a `.system` message appended to `session.messages`, so they interleave in the timeline; you only render the `.system` cases.

```swift
private func systemText(for event: SystemEvent) -> String {
    switch event {
    case .liveAgentJoined(let name): return "\(name ?? "An agent") joined"
    case .queueStatus(let position, let displayMessage):
        if let displayMessage, !displayMessage.isEmpty { return displayMessage }
        return position.map { "Position #\($0) in queue" } ?? "Queued..."
    case .handoffStarted: return "Transferring to a live agent..."
    case .handoffAccepted: return "An agent will be with you shortly"
    case .handoffFailed(let reason): return reason.map { "Transfer failed: \($0)" } ?? "Transfer failed"
    case .handoffTimeout: return "No agents available"
    default: return "This conversation has ended"
    }
}
```

*See [Build your own UI › Live agent handoff](../../../README.md#live-agent-handoff).*

### Live-agent bubble styling — `MessageCell.swift`

`configureAgent` switches on `AgentKind` for bubble color, border, and an
agent-name caption. Live-agent messages flow through `session.messages` as
`AgentMessage` with `agentKind == .live`.

**Under the hood:** live-agent replies arrive as ordinary `.agent` messages on the same rendering path as Poly replies — only `agentKind` (`.live` vs `.poly`) differs, so you tint by it; live-agent typing reuses the existing `isAgentTyping` flag.

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

    // ... text bubble (teal tint when isLive) + attachments + URL cards + call actions ...
}
```

*See [Build your own UI › Live agent handoff](../../../README.md#live-agent-handoff).*

### Typing pill placement — `ChatViewController.swift`

`ChatSession.isAgentTyping` already debounces (SDK invariant I19). The typing
pill is installed as the table footer so it sits directly under the latest
message, matching the SwiftUI `LazyVStack` flow.

**Under the hood:** live-agent typing reuses the same `isAgentTyping` flag as the Poly agent, so the indicator works during handoff with no extra wiring.

```swift
session.$isAgentTyping
    .receive(on: RunLoop.main)
    .sink { [weak self] typing in
        guard let self else { return }
        self.setTypingIndicatorVisible(typing)
    }
    .store(in: &bag)
```

*See [Build your own UI › Live agent handoff](../../../README.md#live-agent-handoff).*

### Why `liveAgentLeft` resets the title

It's terminal — `session.hasEnded` flips true and the existing chat-ended
footer takes over. The title returns to "Chat" so a stale agent name does not
linger into the next conversation.

**Under the hood:** `.liveAgentLeft` is a terminal transition — the SDK is what flips `hasEnded`, so no app-side state tracking is needed to close out the conversation.

## What this example skips

- production-style Resume / Start-New UX → [`../06-FullReference/`](../06-FullReference/)
- raw transport diagnostic tap, full Configuration knobs, and protocol simulations → [`../07-Playground/`](../07-Playground/)

## Copy these into your app

The views in this folder use only **public SDK types**, so they drop into any app
that has the package. To wire them up: [Install the package](../../../README.md#install),
then follow the full walkthrough in root [README → Build your own UI](../../../README.md#build-your-own-ui).

---

SwiftUI counterpart: [`Examples/SwiftUI/05-Handoff/`](../../SwiftUI/05-Handoff/).

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the SwiftUI counterpart. See `SKILL.md §12`.
