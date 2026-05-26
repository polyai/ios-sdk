# 03-RichContent

Adds image attachments, URL cards, `tel:` call actions, and rich text rendering on top of [`02-Standard`](../02-Standard/).

## Run it

```bash
open RichContentSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## New in this level

- `Components/AttachmentCarousel.swift` — horizontal thumbnail strip for `.image` attachments.
- `Components/URLCard.swift` — preview-image + title + CTA card for `.url` attachments.
- `Components/CallActionButton.swift` — green `tel:` button for `ChatCallAction`.
- `Components/RetryableAsyncImage.swift` — `AsyncImage` wrapper with tap-to-retry.
- `Components/RichText.swift` — Markdown → `AttributedString` with plain-text fallback.

`Components/MessageBubbleView.swift` gains the rich-content layout below. Everything else — `ConnectionBanner`, `SuggestionRow`, `TypingIndicator`, the chat scaffold — is inherited from [`02-Standard`](../02-Standard/); see its README.

## How it works

### Image attachments — `Components/AttachmentCarousel.swift`

A horizontal carousel of attachment thumbnails. Tap opens the attachment's `contentUrl` in the system browser. The carousel itself does not filter — the caller (`MessageBubbleView`) passes only `.image` attachments; `.url` attachments are rendered separately by `URLCard`.

**Under the hood:** the SDK decodes `attachments` from the agent message and exposes `contentType` as `.image`/`.url`/`.unknown` — but it never fetches the bytes; you load `previewImageUrl`/`contentUrl` yourself (the caching + tap-to-retry below is app code, not the SDK).

```swift
struct AttachmentCarousel: View {
    let attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                    AttachmentCard(attachment: attachment)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
    }
}
```

*See [Build your own UI › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### URL cards — `Components/URLCard.swift`

`.url` attachments become a card with preview image + title + CTA. Tap opens `contentUrl`.

**Under the hood:** same decoded `Attachment` data — the SDK hands you the `.url`'s `previewImageUrl`, `contentUrl`, and title, and leaves the card layout and link-opening entirely to your code.

```swift
struct URLCard: View {
    let attachment: Attachment
    var body: some View {
        Button {
            if let url = attachment.contentUrl {
                UIApplication.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let preview = attachment.previewImageUrl {
                    RetryableAsyncImage(url: preview) { $0.resizable().scaledToFill() }
                        placeholder: { ProgressView() }
                        fallback: { Image(systemName: "photo") }
                        .frame(width: 260, height: 140).clipped()
                }
                // title + CTA labels …
            }
        }
    }
}
```

*See [Build your own UI › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Call actions — `Components/CallActionButton.swift`

`ChatCallAction` becomes a green `tel:` `Link`. Non-digit characters are stripped from the number (keeping a leading `+`) so display-formatted numbers like `"+1 (555) 123-4567"` still produce a valid URL.

**Under the hood:** each `ChatCallAction` is just decoded data — a `title` and a `contactNumber`. The SDK never dials; building the `tel:` URL and opening it is your code.

```swift
if let url = URL(string: "tel:\(action.contactNumber.filter { $0.isNumber || $0 == "+" })") {
    Link(destination: url) {
        HStack(spacing: 6) {
            Image(systemName: "phone.fill")
            Text(action.title.isEmpty ? action.contactNumber : action.title)
        }
        // .foregroundColor(.white).background(Color.green) …
    }
}
```

*See [Build your own UI › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Retryable images — `Components/RetryableAsyncImage.swift`

A generic wrapper over `AsyncImage` with caller-supplied `content` / `placeholder` /
`fallback` builders. Tap the failure state to retry (it also auto-retries after 5s);
re-keying via a `@State` UUID forces `AsyncImage` to re-fetch.

**Under the hood:** the SDK plays no part here — it only gave you the image URLs. All loading, caching, and retry behaviour lives in this app-side view, so you can swap in whatever image stack you prefer.

```swift
struct RetryableAsyncImage<Content: View, Placeholder: View, Fallback: View>: View {
    let url: URL
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let fallback: () -> Fallback
    @State private var loadId = UUID()

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): content(image)
            case .failure:           fallback().onTapGesture { loadId = UUID() }
            case .empty:             placeholder()
            @unknown default:        fallback()
            }
        }
        .id(loadId)   // re-key forces a fresh fetch
    }
}
```

### Rich text — `Components/RichText.swift`

Renders agent text with inline formatting using a hand-rolled `NSRegularExpression`
pass over the raw string (not `AttributedString(markdown:)`, which chokes on the
partial markdown a stream can emit mid-chunk). Markdown links `[text](url)` and
bare `https://…` URLs become tappable blue links (opened via `OpenURLAction`);
`**bold**`, `*italic*`, and `` `code` `` are styled via `inlinePresentationIntent`.
Anything unmatched falls through as plain text.

**Under the hood:** `AgentMessage.text` is the agent's raw Markdown, passed through untouched (there's no HTML to sanitize) — rendering it is your job. While a reply streams, that text grows and can briefly hold half-open Markdown, which is why this parser tolerates partial input.

*See [Build your own UI › Rich text & links](../../../README.md#rich-text--links).*

> **Streaming:** agent replies grow token-by-token by default (`Configuration.streamingEnabled: true` — ChatGPT-style). Set `streamingEnabled: false` to render completed bubbles only. See the root README's [*Streaming*](../../../README.md#streaming) section and [07-Playground](../07-Playground/) for a live toggle.

```swift
struct RichText: View {
    let raw: String
    init(_ text: String) { self.raw = text }

    var body: some View {
        Text(parse(raw))                       // builds an AttributedString
            .tint(.blue)
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url); return .handled
            })
    }
    // parse(_:) regex-matches [text](url) + bare URLs -> .link;
    // parsePlain(_:) handles **bold** / *italic* / `code`.
}
```

### Bubble layout — `Components/MessageBubbleView.swift`

The agent bubble stacks: rich text → image carousel → URL cards → call actions. `.unknown` content types are dropped silently for forward compat.

**Under the hood:** the SDK groups everything onto one assembled agent message — text, attachments, and call actions all arrive together; `.unknown` is the SDK's forward-compat slot for content types it doesn't model yet, so dropping it is the safe default.

```swift
case .agent(let m):
    VStack(alignment: .leading, spacing: 8) {
        if !m.text.isEmpty { RichText(m.text) /* … */ }

        let images = m.attachments.filter { $0.contentType == .image }
        if !images.isEmpty { AttachmentCarousel(attachments: images) }

        let urls = m.attachments.filter { $0.contentType == .url }
        if !urls.isEmpty {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, att in
                URLCard(attachment: att)
            }
        }

        ForEach(m.callActions) { CallActionButton(action: $0) }
    }
```

## What this example skips

- offline detection, loading skeleton, terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

## Copy these into your app

The views in this folder use only **public SDK types** (`ChatMessage`, `Attachment`, `ChatCallAction`, …), so they drop into any app that has the package. Add the package (root [README → Install](../../../README.md#install)) and drive these views from `ChatSession` — full walkthrough in root [README → "Build your own UI"](../../../README.md#build-your-own-ui).

---

UIKit counterpart: [`Examples/UIKit/03-RichContent/`](../../UIKit/03-RichContent/).

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the UIKit counterpart. See `SKILL.md §12`.
