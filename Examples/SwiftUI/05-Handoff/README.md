# 05-Handoff (SwiftUI)

Live-agent handoff on top of [`04-Resilience`](../04-Resilience/). Queue / accept / fail / agent-joined events become centered system pills in the transcript; live-agent bubbles get distinct styling.

## Run it

```bash
open HandoffSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your connector token in `HandoffApp.swift` (currently `"YOUR_CONNECTOR_TOKEN"`).

## What this example demonstrates

- Render handoff progress (queue / accept / fail / timeout) as centered `.system` pills
- Tint a live-agent bubble teal and tag the caption with `· live agent`
- Subscribe to raw `client.events` for app side effects (set the nav title, deep-link a route)
- Reuse `session.isAgentTyping` for live-agent typing — no new flag needed
- Let `.liveAgentLeft` flip `session.hasEnded` naturally so the existing chat-ended footer takes over

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide); this example shows them as one concrete view.

## How it works

Each subsection leads with **the SDK call** (one or a few lines — the actual API), then shows **how it's wired into a view**.

### Handoff status pills — `Components/MessageBubbleView.swift`

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
// .liveAgentLeft                 // terminal — chatEnded follows
```

In a view (inside `MessageBubbleView`'s system branch):

```swift
case .system(let m):
    HStack {
        Spacer()
        Text(systemText(for: m.event))
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        Spacer()
    }

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
```

**Under the hood:** the SDK converts every handoff transition — agent-triggered handoff, queue status, accepted / failed / timeout, live-agent joined / left — into a `.system` message appended to `session.messages`. They interleave with `.user` / `.agent` bubbles in the timeline, so you only render the `.system` branch and the order comes out right for free.

*See [Integration guide › Agent handoff](../../../README.md#agent-handoff).*

### Live-agent bubble styling — `Components/MessageBubbleView.swift`

Live-agent replies are ordinary `.agent` messages — the same rendering path as Poly agent replies. Switch on `AgentMessage.agentKind` to tint them and tag the caption:

The SDK signal:

```swift
AgentMessage.agentKind   // .poly (default) or .live — live = a human handled by handoff
AgentMessage.agentName   // optional display name (used for the caption)
```

In a view (inside `MessageBubbleView`'s agent branch):

```swift
private func agentRow(_ m: AgentMessage) -> some View {
    let isLive = (m.agentKind == .live)

    return HStack(alignment: .top, spacing: 8) {
        avatar(url: m.avatarUrl, isLive: isLive)   // teal ring overlay when isLive

        VStack(alignment: .leading, spacing: 4) {
            if let name = m.agentName, !name.isEmpty {
                Text(isLive ? "\(name) · live agent" : name)
                    .font(.caption2)
                    .foregroundColor(isLive ? .teal : .secondary)
            }
            RichText(m.text)
                .padding(10)
                .background(isLive ? Color.teal.opacity(0.18) : Color(.systemGray5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isLive ? Color.teal.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))

            // ...attachments + URL cards + call actions...
        }
    }
}
```

**Under the hood:** the SDK normalises live-agent replies into the same `AgentMessage` shape as Poly replies — only `agentKind` and (usually) `avatarUrl` / `agentName` differ. Live-agent typing reuses `session.isAgentTyping`, so the typing indicator works during handoff with no extra wiring.

> **Streaming:** agent replies grow token-by-token by default (`Configuration.streamingEnabled: true` — ChatGPT-style). Live-agent messages flow through the same path, so streaming works for them too. See the root README's [*Streaming*](../../../README.md#streaming) section and [`07-Playground`](../07-Playground/) for a live toggle.

*See [Integration guide › Agent handoff](../../../README.md#agent-handoff).*

### Side effects via raw `client.events` — `Views/ContentView.swift`

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

In a view:

```swift
struct ContentView: View {
    @StateObject var session = PolyMessaging.chat()
    @State private var connectedAgentName: String? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ...banners + message list + composer...
            }
            .navigationTitle(connectedAgentName ?? "Chat")
            // Cancelled automatically when the view leaves the hierarchy.
            .task {
                for await event in session.client.events {
                    handle(event: event)
                }
            }
        }
    }

    private func handle(event: MessagingEvent) {
        switch event {
        case .liveAgentJoined(_, let p):
            connectedAgentName = p.agentName
        case .clientHandoffRequired(_, let p):
            // Optionally deep-link to the route URL if it parses.
            if let route = p.route, let url = URL(string: route),
               let scheme = url.scheme, scheme.hasPrefix("http") {
                UIApplication.shared.open(url)
            }
        case .liveAgentLeft, .sessionStart:
            connectedAgentName = nil
        default:
            // Handoff progress flows through session.messages as SystemMessage
            // pills (rendered above). isAgentTyping covers live-agent typing.
            // .liveAgentMessage flows into session.messages as an AgentMessage
            // with agentKind == .live.
            break
        }
    }
}
```

**Under the hood:** `client.events` is the same typed, decoded stream the SDK uses internally — subscribing adds no transport overhead, and is the right place for imperative side effects (nav title, analytics, deep-linking) that aren't a function of `messages`. Anything renderable already comes through `session.messages` / `session.isAgentTyping`, so don't drive the bubble list off this stream.

*See [Integration guide › Agent handoff](../../../README.md#agent-handoff).*

### Why `liveAgentLeft` needs no special handling

It's terminal — `session.hasEnded` flips true and the existing chat-ended footer takes over. The title returns to "Chat" (handled in `.liveAgentLeft` above) so a stale agent name doesn't linger into the next conversation.

**Under the hood:** `.liveAgentLeft` is a terminal transition — the SDK itself flips `hasEnded`, so no app-side bookkeeping is needed to close out the conversation.

## What this example skips

- production-style resume / start-new flow with a dedicated connect screen → [`06-FullReference/`](../06-FullReference/)
- runtime configuration, raw transport experiments, diagnostics → [`07-Playground/`](../07-Playground/)

---

- **UIKit counterpart:** [`Examples/UIKit/05-Handoff/`](../../UIKit/05-Handoff/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
