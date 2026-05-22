# Examples — read this first

**Examples are the source of truth; README is the documentation surface.** Every code snippet in the project [README](../README.md) reflects what one of these example projects actually does. When the two diverge, the example wins and the README is wrong — fix the README, not the example.

This is enforced by convention, not tooling. The two can diverge silently. Every contributor must check.

## When you change an example

Grep the README for any snippet that references the same pattern, function name, property access, or comment. Update those snippets in the README too. Then check the matching example in the *other* framework (SwiftUI ↔ UIKit at the same level) — feature sets must stay aligned across the ladder.

## When you change a README snippet

First add the pattern to the relevant example (in BOTH SwiftUI and UIKit at the same level), verify it compiles, then promote the snippet to README. A snippet that exists only in README is a red flag — it rots.

## The ladder

| Level | Demonstrates | SwiftUI | UIKit |
|---|---|---|---|
| **01-Hello** | `initialize`, `chat()`, render `session.messages`, `send()` | [`SwiftUI/01-Hello/`](SwiftUI/01-Hello/) | [`UIKit/01-Hello/`](UIKit/01-Hello/) |
| **02-Standard** | + typing indicator, connection banner, suggestion pills, delivery state, end + start new chat, failure retry | [`SwiftUI/02-Standard/`](SwiftUI/02-Standard/) | [`UIKit/02-Standard/`](UIKit/02-Standard/) |
| **03-RichContent** | + image attachments, URL cards, `tel:` call actions, **Markdown/link parsing in agent messages** (`RichText` / `MessageCell.renderMarkdown` — copy this for rendering formatted text & tappable links), retryable image loading | [`SwiftUI/03-RichContent/`](SwiftUI/03-RichContent/) | [`UIKit/03-RichContent/`](UIKit/03-RichContent/) |
| **04-Resilience** | + `NWPathMonitor`-backed offline banner, loading skeleton, terminal error screen with manual retry | [`SwiftUI/04-Resilience/`](SwiftUI/04-Resilience/) | [`UIKit/04-Resilience/`](UIKit/04-Resilience/) |
| **05-Handoff** | + full live-agent ladder: raw event side effects, handoff status pills, live-agent bubble styling | [`SwiftUI/05-Handoff/`](SwiftUI/05-Handoff/) | [`UIKit/05-Handoff/`](UIKit/05-Handoff/) |
| **06-FullReference** | + production-style Resume + Start-New flows without developer diagnostics | [`SwiftUI/06-FullReference/`](SwiftUI/06-FullReference/) | [`UIKit/06-FullReference/`](UIKit/06-FullReference/) |
| **07-Playground** | + progressive (token-by-token) streaming toggle, raw transport diagnostic tap, event log, runtime Configuration knobs, and protocol simulations | [`SwiftUI/07-Playground/`](SwiftUI/07-Playground/) | [`UIKit/07-Playground/`](UIKit/07-Playground/) |

Across all levels, UIKit L*N* demonstrates the same feature set as SwiftUI L*N* — only the UI binding differs. (UIKit 06-07 are built programmatically without a storyboard, since their connect/loading/chat/error screens swap a single container.)

## Running an example

Each example ships a generated `.xcodeproj` alongside the `project.yml` that produced it (via [xcodegen](https://github.com/yonomoto/XcodeGen)). To run:

```bash
open Examples/SwiftUI/01-Hello/HelloSwiftUI.xcodeproj   # or any other
# Cmd+R on an iPhone simulator
```

If you change `project.yml`, regenerate with `xcodegen` from inside that folder. Each example has a per-folder `README.md` documenting what's new at that level. Set your connector token where the example calls `PolyMessaging.initialize(...)`.
