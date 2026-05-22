# Shared UI components

The **canonical, copy-paste UI components** for PolyMessaging — one version each,
taken from `06-FullReference` (the production-grade reference). The example ladder
(`01`–`07`) uses these same components; this folder is the single place to grab
them from when building your own app.

Every file uses **only public SDK types** (`ChatMessage`, `Attachment`,
`ResponseSuggestion`, `ChatCallAction`, `ConnectionStatus`) — no SDK internals —
so each one drops into any app that has the package (see the root
[README → Install](../../README.md#install)).

Layout (mirrors the example apps): the reusable **components** sit at the top of
`SwiftUI/` and `UIKit/`; full **screens** are under `Screens/`, non-view
**helpers** under `Helpers/`, and view-models under `Models/`.

## SwiftUI (`Components/SwiftUI/`)

| File | Renders |
|---|---|
| `MessageBubbleView.swift` | user + agent bubbles, system pills, avatar (composition root) |
| `RichText.swift` | agent Markdown → `AttributedString` (links, bold) |
| `AttachmentCarousel.swift` | image **and** URL-card attachments, horizontally scrolling |
| `CallActionButton.swift` | `tel:` call buttons |
| `RetryableAsyncImage.swift` | remote images with tap-to-retry |
| `SuggestionRow.swift` | quick-reply pills |
| `TypingIndicator.swift` | animated agent-typing dots |
| `LoadingSkeleton.swift` | first-load placeholder |
| `Screens/` — `ConnectView`, `LoadingView`, `ErrorScreen`, `ChatView` | resume-or-start, loading, error, full chat screens |
| `Helpers/NetworkMonitor.swift` | `NWPathMonitor` wrapper for offline detection |
| `Helpers/InteractiveKeyboardDismiss.swift` | iOS-15-safe interactive keyboard dismiss |
| `Models/ChatModels.swift` | small view-model conveniences |

## UIKit (`Components/UIKit/`)

| File | Renders |
|---|---|
| `MessageCell.swift` | user + agent + system cells (Markdown, attachments, suggestions, call actions) |
| `AttachmentCarouselView.swift` | image attachments, horizontally scrolling |
| `URLCardView.swift` | link cards (preview image + title + CTA) |
| `CallActionsRow.swift` | `tel:` call buttons |
| `RetryableImageView.swift` | remote images with tap-to-retry |
| `SuggestionsView.swift` | quick-reply pills |
| `LoadingSkeleton.swift` | first-load placeholder |
| `OfflineBanner.swift` | offline / reconnecting bar |
| `Screens/` view controllers (`ChatViewController`, `ConnectViewController`, `LoadingViewController`, `ErrorViewController`) | reference screens (Combine `.sink` on `ChatSession`) |
| `Helpers/NetworkMonitor.swift` | `NWPathMonitor` wrapper for offline detection |

> SwiftUI and UIKit render the **same feature set** — one carousel concept, one
> suggestion concept, etc. — only the binding differs (SwiftUI `@StateObject`
> vs UIKit Combine `.sink`). These files are byte-for-byte the `06-FullReference`
> components, which are exercised by that app's XCUITest against the live backend.

## How to use

1. Add the package (root [README → Install](../../README.md#install)).
2. Copy the files you need from `SwiftUI/` or `UIKit/`.
3. Drive them from `ChatSession` — bind `session.messages` and render each
   `ChatMessage`; set your token + environment in `PolyMessaging.initialize(...)`.

Full walkthrough: root [README → "Build your own UI"](../../README.md#build-your-own-ui).
