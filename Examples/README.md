# Examples

Each example is a runnable app that builds on the previous one. UIKit L*N* covers the same features as SwiftUI L*N* — only the binding differs.

| Level | What it covers | SwiftUI | UIKit |
|---|---|---|---|
| **01-Hello** | `initialize`, `chat()`, render `session.messages`, `send()` | [`SwiftUI/01-Hello/`](SwiftUI/01-Hello/) | [`UIKit/01-Hello/`](UIKit/01-Hello/) |
| **02-Standard** | typing indicator, connection banner, suggestion pills, delivery state, end + start new chat, failure retry | [`SwiftUI/02-Standard/`](SwiftUI/02-Standard/) | [`UIKit/02-Standard/`](UIKit/02-Standard/) |
| **03-RichContent** | image attachments, URL cards, `tel:` call actions, Markdown/link parsing, retryable image loading | [`SwiftUI/03-RichContent/`](SwiftUI/03-RichContent/) | [`UIKit/03-RichContent/`](UIKit/03-RichContent/) |
| **04-Resilience** | `NWPathMonitor` offline banner, loading skeleton, terminal error screen with manual retry | [`SwiftUI/04-Resilience/`](SwiftUI/04-Resilience/) | [`UIKit/04-Resilience/`](UIKit/04-Resilience/) |
| **05-Handoff** | live-agent handoff: raw event side effects, handoff status pills, live-agent bubble styling | [`SwiftUI/05-Handoff/`](SwiftUI/05-Handoff/) | [`UIKit/05-Handoff/`](UIKit/05-Handoff/) |
| **06-FullReference** | production-style Resume + Start-New flows (no developer diagnostics) | [`SwiftUI/06-FullReference/`](SwiftUI/06-FullReference/) | [`UIKit/06-FullReference/`](UIKit/06-FullReference/) |
| **07-Playground** | streaming toggle, raw transport diagnostic tap, event log, runtime `Configuration` knobs, protocol simulations | [`SwiftUI/07-Playground/`](SwiftUI/07-Playground/) | [`UIKit/07-Playground/`](UIKit/07-Playground/) |

Separate from the chat ladder, **Voice** is a tap-to-call WebRTC demo on the [`PolyVoice`](../docs/PolyVoice.md) product (needs a physical device — the simulator can't carry WebRTC media): [`SwiftUI/Voice/`](SwiftUI/Voice/) · [`UIKit/Voice/`](UIKit/Voice/).

UIKit 06–07 are built programmatically (no storyboard) so their connect/loading/chat/error screens can swap a single container.

The **03**, **06**, and **07** examples (SwiftUI and UIKit) also ship a foreground-only new-message notification banner — a local notification when the agent replies while the app is open, in `Components/NewMessageNotifier.swift`. There's deliberately no background path; see the root README's [In-app new-message alerts (foreground only)](../README.md#in-app-new-message-alerts-foreground-only).

## Running

Each example ships a generated `.xcodeproj` alongside the `project.yml` that produced it (via [xcodegen](https://github.com/yonaskolb/XcodeGen)).

```bash
open Examples/SwiftUI/01-Hello/HelloSwiftUI.xcodeproj   # or any other
# Cmd+R on an iPhone simulator
```

If you change `project.yml`, regenerate with `xcodegen` from inside that folder. Set your API key where the example calls `PolyMessaging.initialize(...)`.
