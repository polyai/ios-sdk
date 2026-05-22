# 05-Handoff

The full live-agent handoff ladder on top of [`04-Resilience`](../04-Resilience/).
Handoff progress renders as centered chat pills, matching L2, while live-agent
bubbles get distinct styling.

## Run it

```bash
open HandoffSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## New in this level

**No new files.** Every file is inherited verbatim from [`04-Resilience`](../04-Resilience/) — handoff is entirely a matter of handling events the SDK already surfaces. The new logic lives in two files that gain code:

- `Views/ContentView.swift` — subscribes to raw `MessagingEvent`s for app side effects (set title on `liveAgentJoined`, open the `clientHandoffRequired` route).
- `Components/MessageBubbleView.swift` — renders handoff/queue progress as centered system pills and styles live-agent bubbles (`agentKind == .live`).

Everything `ChatSession` already does for handoff — turning queue/accept/fail events into `SystemMessage` rows — needs no app code.

## How it works

### Subscribe to raw events — `Views/ContentView.swift`

`ChatSession` already turns handoff progress into `SystemMessage` rows in
`session.messages`. The raw event subscription only handles app side effects:
setting the navigation title when a live agent joins and opening a client
handoff route when the backend asks for one.

**Under the hood:** the raw `client.events` stream is only needed for imperative side effects like deep-linking a `clientHandoffRequired` route or analytics — rendering reads `session.messages`, never this stream.

```swift
private func handle(event: MessagingEvent) {
    switch event {
    case .liveAgentJoined(_, let p):
        connectedAgentName = p.agentName
    case .clientHandoffRequired(_, let p):
        if let route = p.route, let url = URL(string: route),
           let scheme = url.scheme, scheme.hasPrefix("http") {
            UIApplication.shared.open(url)
        }
    case .liveAgentLeft, .sessionStart:
        connectedAgentName = nil
    default:
        break
    }
}
```

*See [Build your own UI › Side effects: `client.events`](../../../README.md#side-effects-clientevents).*

### Handoff status pills — `Components/MessageBubbleView.swift`

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

### Live-agent bubble styling — `Components/MessageBubbleView.swift`

`agentRow` switches on `AgentMessage.agentKind` for bubble color, border, and
an agent-name caption. Live-agent messages flow through `session.messages` as
`AgentMessage` with `agentKind == .live`.

**Under the hood:** live-agent replies arrive as ordinary `.agent` messages on the same rendering path as Poly replies — only `agentKind` (`.live` vs `.poly`) differs, so you tint by it; live-agent typing reuses the existing `isAgentTyping` flag.

```swift
private func agentRow(_ m: AgentMessage) -> some View {
    let isLive = (m.agentKind == .live)

    return HStack(alignment: .top, spacing: 8) {
        avatar(url: m.avatarUrl, isLive: isLive)

        VStack(alignment: .leading, spacing: 4) {
            if let name = m.agentName, !name.isEmpty {
                Text(isLive ? "\(name) · live agent" : name)
                    .font(.caption2)
                    .foregroundColor(isLive ? .teal : .secondary)
            }

            // ... text + attachments + URL cards + call actions ...
        }
    }
}
```

*See [Build your own UI › Live agent handoff](../../../README.md#live-agent-handoff).*

### Why `liveAgentLeft` resets the title

It's terminal — `session.hasEnded` flips true and the existing `chatEndedFooter`
takes over. The title returns to "Chat" so a stale agent name does not linger
into the next conversation.

**Under the hood:** `.liveAgentLeft` is a terminal transition — the SDK is what flips `hasEnded`, so no app-side state tracking is needed to close out the conversation.

## What this example skips

- production-style Resume / Start-New UX → [`../06-FullReference/`](../06-FullReference/)
- raw transport diagnostic tap, full Configuration knobs, and protocol simulations → [`../07-Playground/`](../07-Playground/)

## Copy these into your app

The views in this folder use only **public SDK types**, so they drop into any app
that has the package. To wire them up: [Install the package](../../../README.md#install),
then follow the full walkthrough in root [README → Build your own UI](../../../README.md#build-your-own-ui).

---

UIKit counterpart: [`Examples/UIKit/05-Handoff/`](../../UIKit/05-Handoff/).

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the UIKit counterpart. See `SKILL.md §12`.
