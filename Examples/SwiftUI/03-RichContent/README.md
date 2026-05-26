# 03-RichContent (SwiftUI)

Adds image attachments, URL link cards, `tel:` call actions, and Markdown rendering on top of [`02-Standard`](../02-Standard/).

Setup, scaffolding, and everything inherited from 02 (typing, suggestions, delivery, reconnect, end + start-new) are unchanged — read [`02-Standard`](../02-Standard/) first. This README covers only what 03 adds.

## Run it

```bash
open RichContentSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your connector token in `App/RichContentApp.swift` (currently `"YOUR_CONNECTOR_TOKEN"`).

## What this example demonstrates

- Image attachments — `AgentMessage.attachments` filtered by `contentType == .image`
- URL link cards — same `attachments` array filtered by `.url`
- `tel:` call buttons — `AgentMessage.callActions`
- Markdown rendering — `AgentMessage.text` (raw Markdown, you parse)
- Forward-compat: drop `.unknown` content types silently

**The SDK decodes the data; it never fetches bytes or dials phones.** You own image loading, caching, retry, link-opening, and the `tel:` `URL`. This example shows one way to do all of that with stock SwiftUI.

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide).

## How it works

Each subsection leads with **the SDK data** (the actual API), then shows **how it's wired into the agent bubble**.

### Render image attachments — inside the `.agent` branch

What the SDK gives you:

```swift
m.attachments   // [Attachment] — agent messages only. Each carries:
                //   contentType   — .image / .url / .unknown (drop .unknown for forward-compat)
                //   contentUrl    — URL? — where the asset lives
                //   previewImageUrl — URL? — smaller preview (often nil for raw images)
                //   title         — String? / callToActionText — String?
                // The SDK never fetches bytes — you load the URL with AsyncImage / URLSession.
```

In a view — render only `.image` attachments inside the `.agent` branch of your bubble switch:

```swift
ForEach(session.messages) { message in
    switch message {
    case .agent(let m):
        VStack(alignment: .leading, spacing: 8) {
            Text(m.text)              // ...your existing agent text bubble...

            let images = m.attachments.filter { $0.contentType == .image }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images, id: \.contentUrl) { att in
                            AsyncImage(url: att.contentUrl) { $0.resizable().scaledToFill() }
                                placeholder: { Color(.systemGray5) }
                                .frame(width: 220, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }

    // ...other cases (.user, .system) — see the core pattern...
    default: EmptyView()
    }
}
```

**Under the hood:** the SDK decodes the agent's `attachments` array from the protocol payload and groups them onto the same `AgentMessage` as the text. No background fetch happens — you load `contentUrl` / `previewImageUrl` yourself. Stock `AsyncImage` is enough for most apps; this example uses a small wrapper (`RetryableAsyncImage`) that adds tap-to-retry on failure.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render URL link cards — same `attachments`, filtered by `.url`

What the SDK gives you:

```swift
att.contentUrl         // URL? — destination link
att.previewImageUrl    // URL? — preview image (often present; falls back to contentUrl)
att.title              // String? — card headline
att.callToActionText   // String? — button label, e.g. "Learn more"
```

In a view:

```swift
let urls = m.attachments.filter { $0.contentType == .url }
ForEach(urls, id: \.contentUrl) { att in
    if let url = att.contentUrl {
        Link(destination: url) {
            VStack(alignment: .leading, spacing: 0) {
                if let preview = att.previewImageUrl {
                    AsyncImage(url: preview) { $0.resizable().scaledToFill() }
                        placeholder: { Color(.systemGray5) }
                        .frame(width: 260, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if let title = att.title {
                    Text(title).font(.subheadline.bold()).padding(.top, 6)
                }
                if let cta = att.callToActionText {
                    Text(cta).font(.caption).foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
```

**Under the hood:** same decoded `Attachment` data — the SDK hands you the URL + preview + title, and leaves the card layout and link-opening entirely to your code. `Link(destination:)` opens via the user's default browser; swap for `Button` + `openURL` if you want to intercept (e.g. open in-app).

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render `tel:` call buttons — `AgentMessage.callActions`

What the SDK gives you:

```swift
m.callActions   // [ChatCallAction] — agent messages only. Each:
                //   title          — String — button label, e.g. "Call now"
                //   contactNumber  — String — may be display-formatted ("+1 (555) 123-4567")
                // The SDK never dials — you build the tel: URL and open it.
```

In a view:

```swift
@Environment(\.openURL) private var openURL

ForEach(m.callActions) { action in
    Button {
        // Strip non-digits (keep leading +) so display-formatted numbers still produce a valid URL.
        let digits = action.contactNumber.filter { $0.isNumber || $0 == "+" }
        if let url = URL(string: "tel:\(digits)") { openURL(url) }
    } label: {
        HStack(spacing: 6) {
            Image(systemName: "phone.fill")
            Text(action.title.isEmpty ? action.contactNumber : action.title)
        }
    }
    .buttonStyle(.borderedProminent)
    .tint(.green)
}
```

**Under the hood:** the SDK delivers `ChatCallAction` as decoded data — `title` + `contactNumber`. Dialling is your code: sanitise the number (digits + leading `+`), build `tel:<digits>`, hand to `openURL` / `UIApplication.shared.open`.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render Markdown — `AgentMessage.text`

What the SDK gives you:

```swift
m.text   // String — the agent's raw Markdown (no HTML; nothing to sanitize).
         // Grows in place during streaming and can briefly hold half-open Markdown
         // (e.g. a trailing `**` waiting for its closer) — your parser should tolerate that.
```

In a view — Apple's `AttributedString(markdown:)` handles bold/italic/`code`/`[links](url)`. It does **not** linkify bare `https://…` URLs; add a regex pass if your agent emits them.

```swift
let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
if let attributed = try? AttributedString(markdown: m.text, options: opts) {
    Text(attributed)
} else {
    Text(m.text)              // fall back to plain text during half-open Markdown
}
```

**Under the hood:** the SDK passes the agent's Markdown through untouched. Streaming chunks update `m.text` in place; the parse-failure fallback to plain text keeps the bubble readable mid-stream until the next chunk lands.

*See [Integration guide › Rich text & links](../../../README.md#rich-text--links).*

### Bubble layout — compose everything

The agent bubble stacks: text → image carousel → URL cards → call actions. `.unknown` content types are dropped silently for forward-compat.

```swift
case .agent(let m):
    VStack(alignment: .leading, spacing: 8) {
        if !m.text.isEmpty { /* RichText / AttributedString render */ }

        let images = m.attachments.filter { $0.contentType == .image }
        if !images.isEmpty { /* ScrollView + AsyncImage row */ }

        let urls = m.attachments.filter { $0.contentType == .url }
        ForEach(urls, id: \.contentUrl) { /* URL card */ }

        ForEach(m.callActions) { /* tel: button */ }
    }
```

**Under the hood:** the SDK delivers text, attachments, and call actions on one assembled `AgentMessage` — no separate events to coordinate. `.unknown` is the SDK's forward-compat slot for content types it doesn't model yet; dropping it (instead of falling through to a placeholder) is the safe default.

## What this example skips

- offline detection, loading skeleton, full-screen terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

---

- **UIKit counterpart:** [`Examples/UIKit/03-RichContent/`](../../UIKit/03-RichContent/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
