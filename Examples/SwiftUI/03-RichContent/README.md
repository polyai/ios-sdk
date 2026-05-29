# 03-RichContent (SwiftUI)

Adds image attachments, URL link cards, `tel:` call actions, and Markdown rendering on top of [`02-Standard`](../02-Standard/).

Setup, scaffolding, and everything inherited from 02 (typing, suggestions, delivery, reconnect, end + start-new) are unchanged — read [`02-Standard`](../02-Standard/) first. This README covers only what 03 adds.

## Run it

```bash
open RichContentSwiftUI.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your API key in `App/RichContentApp.swift` (currently `"YOUR_API_KEY"`).

## What this example demonstrates

- Image attachments — `AgentMessage.attachments` filtered by `contentType == .image`
- URL link cards — same `attachments` array filtered by `.url`
- `tel:` call buttons — `AgentMessage.callActions`
- Markdown **and** a small HTML subset — `AgentMessage.text` (Markdown, plus tags like `<br>` normalized to match the web chat widget)
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

In a view — render only `.image` attachments inside the `.agent` branch of your bubble switch. The example wraps each thumbnail in a `Button` that opens `contentUrl`, and uses a `RetryableAsyncImage` helper (in `Components/`) that wraps `AsyncImage` and adds tap-to-retry + a 5-second auto-retry on failure:

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
                        ForEach(Array(images.enumerated()), id: \.offset) { _, att in
                            Button {
                                if let url = att.contentUrl { UIApplication.shared.open(url) }
                            } label: {
                                RetryableAsyncImage(url: att.previewImageUrl ?? att.contentUrl!) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 220, height: 140).clipped()
                                } placeholder: {
                                    ProgressView().frame(width: 220, height: 140)
                                } fallback: {
                                    Rectangle().fill(Color(.systemGray4))
                                        .frame(width: 220, height: 140)
                                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(att.contentUrl == nil)
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

**Under the hood:** the SDK decodes the agent's `attachments` array from the protocol payload and groups them onto the same `AgentMessage` as the text. No background fetch happens — you load `contentUrl` / `previewImageUrl` yourself. Stock `AsyncImage` is enough for most apps; this example wraps it in `RetryableAsyncImage` (`Components/RetryableAsyncImage.swift`) which keys the request on a `loadId` `UUID` so tapping the failure state forces a fresh fetch, and schedules a one-shot retry 5 seconds later.

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
ForEach(Array(urls.enumerated()), id: \.offset) { _, att in
    Button {
        if let url = att.contentUrl { UIApplication.shared.open(url) }
    } label: {
        VStack(alignment: .leading, spacing: 0) {
            if let preview = att.previewImageUrl {
                RetryableAsyncImage(url: preview) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack { Color(.systemGray5); ProgressView() }
                } fallback: {
                    ZStack { Color(.systemGray5); Image(systemName: "photo").foregroundColor(.secondary) }
                }
                .frame(width: 260, height: 140)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                if let title = att.title { Text(title).font(.subheadline.bold()) }
                if let cta = att.callToActionText { Text(cta).font(.caption.bold()).foregroundColor(.blue) }
            }
            .padding(10)
        }
        .frame(width: 260)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .disabled(att.contentUrl == nil)
}
```

**Under the hood:** same decoded `Attachment` data — the SDK hands you the URL + preview + title, and leaves the card layout and link-opening entirely to your code. The example uses `Button` + `UIApplication.shared.open(url)` (rather than `Link(destination:)`) so the tap target covers the whole card and you can intercept (e.g. route in-app) if you need to.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render `tel:` call buttons — `AgentMessage.callActions`

What the SDK gives you:

```swift
m.callActions   // [ChatCallAction] — agent messages only. Each:
                //   title          — String — button label, e.g. "Call now"
                //   contactNumber  — String — may be display-formatted ("+1 (555) 123-4567")
                // The SDK never dials — you build the tel: URL and open it.
```

In a view — build a sanitised `tel:` URL and hand it to a SwiftUI `Link`. `Link` opens the URL via the system handler (which kicks off the system call-prompt for `tel:`), so there's no `@Environment(\.openURL)` plumbing to wire up:

```swift
ForEach(m.callActions) { action in
    // Strip non-digits (keep leading +) so display-formatted numbers still produce a valid URL.
    if let url = URL(string: "tel:\(action.contactNumber.filter { $0.isNumber || $0 == "+" })") {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                Text(action.title.isEmpty ? action.contactNumber : action.title)
            }
            .font(.subheadline.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.green)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
```

**Under the hood:** the SDK delivers `ChatCallAction` as decoded data — `title` + `contactNumber`. Dialling is your code: sanitise the number (digits + leading `+`), build `tel:<digits>`, hand to a `Link`. (`Button { openURL(url) }` works too if you need to intercept; this example uses `Link` for the simpler call site.)

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render Markdown — `AgentMessage.text`

What the SDK gives you:

```swift
m.text   // String — the agent's text, delivered raw. Usually Markdown (**bold**,
         // *italic*, `code`, [links](url)) — but it can also carry a small subset of
         // HTML, most often `<br>` line breaks, because the backend serves the SAME
         // message to the web chat widget, which renders it as HTML. The SDK does not
         // strip or convert it, so the rich examples normalize that subset themselves.
         // Grows in place during streaming and can briefly hold half-open Markdown
         // (e.g. a trailing `**` waiting for its closer) — your parser should tolerate that.
```

In a view — Apple's `AttributedString(markdown:)` handles `[links](url)` + `**bold**`/`*italic*`/`` `code` `` inline, but it does **not** linkify bare `https://…` URLs, **nor convert HTML** (a literal `<br>` would show as text). So the example's `RichText` view (in `Components/`) first runs `normalizeAgentHTML` — mapping the same HTML allow-list the web widget permits (`a, br, b, i, em, strong, p, ul, ol, li, code`) to newlines + Markdown — then runs a regex pass for both Markdown `[text](url)` and bare URLs, then folds bold/italic/code on top. Drop it in and pass `m.text`:

```swift
// Components/RichText.swift — the example's renderer (see the file for the full body).
struct RichText: View {
    let raw: String
    init(_ text: String) { self.raw = Self.normalizeAgentHTML(text) }   // HTML → newlines + Markdown first
    // normalizeAgentHTML(_:) — `<br>`→newline, `<b>/<strong>`→**, `<i>/<em>`→*, `<a href>`→[text](url),
    //                          lists→bullets, decode entities, drop any other tag (mirrors DOMPurify).

    var body: some View {
        Text(parse(raw))              // Markdown links + bare URLs + bold/italic/code → AttributedString
            .tint(.blue)
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url); return .handled
            })
    }
    // parse(_:) — regex pass for `[text](url)` and bare `https?://…`, then fold `**bold**` / `*italic*` / `\`code\`` over the gaps.
}

// At the call site, inside .agent:
RichText(m.text)
```

**Under the hood:** the SDK passes the agent's text through untouched. Streaming chunks update `m.text` in place; the regex parser tolerates half-open Markdown (e.g. an unclosed `**`) by leaving it as literal text until the next chunk closes it. If your agent never emits bare URLs, swap `RichText` for `Text(try AttributedString(markdown: m.text))` — Apple's parser handles `[text](url)` + bold/italic/code on its own.

> **Why normalize HTML?** Agent content is authored once and rendered on both web and mobile. The web widget pipes it through `marked` + DOMPurify, so a reply like `…Customer Care. 👋<br><br>How can I help?` reaches every client with **literal `<br>` tags**. SwiftUI's `Text` would show them raw. `normalizeAgentHTML` mirrors the web's DOMPurify allow-list (`a, br, b, i, em, strong, p, ul, ol, li, code`) — converting `<br>` to a line break, `<b>`→`**`, `<a href>`→`[text](url)`, etc., and dropping anything else — so the bubble matches the web. The minimal [`01-Hello`](../01-Hello/) / [`02-Standard`](../02-Standard/) examples intentionally skip this (they render `m.text` with a plain `Text` to stay minimal), so they show `<br>` raw — add `normalizeAgentHTML` there too if your agent emits HTML.

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
