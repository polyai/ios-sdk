# 03-RichContent (UIKit)

UIKit equivalent of [`../../SwiftUI/03-RichContent/`](../../SwiftUI/03-RichContent/). Adds image attachments, URL cards, `tel:` call actions, retryable image loading, and Markdown rendering on top of [`02-Standard`](../02-Standard/).

## Run it

```bash
open RichContentUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

## New in this level

- `AttachmentCarouselView.swift` — horizontal `UIScrollView` strip of cards. `MessageCell` uses two: one for `.image` attachments, one for `.url` link-cards.
- `URLCardView.swift` — a compact preview + title + CTA card (the copy-from variant for a vertical URL list; this level renders URL attachments through the carousel above).
- `CallActionsRow.swift` — row of `tel:` call-action buttons.
- `RetryableImageView.swift` — `UIImageView` wrapper with tap-to-retry.

`MessageCell.swift` gains the rich-content stack (markdown text + the views above). Everything else — the chat scaffold, suggestions, typing, reconnect banner — is inherited from [`02-Standard`](../02-Standard/); see its README.

## How it works

Everything that 02-Standard does, plus the rich content below — laid out programmatically inside `MessageCell`'s vertical `outerStack`:

```swift
outerStack.addArrangedSubview(bubbleRow)    // markdown-rendered text (in a UITextView)
outerStack.addArrangedSubview(carousel)     // image attachments
outerStack.addArrangedSubview(urlCarousel)  // URL link-cards (same card, also horizontal)
outerStack.addArrangedSubview(callActions)  // tel: buttons
```

Each subview hides itself when the message has nothing to put in it.

### Image attachments — `AttachmentCarouselView.swift`

A horizontal `UIScrollView` holding a `UIStackView` of 220pt-wide cards (140pt `RetryableImageView` preview on top, optional title/CTA below). `MessageCell` passes only `.image` attachments here; tapping a card opens its `contentUrl`.

**Under the hood:** the SDK decodes `attachments` from the agent message and tags each `contentType` as `.image`/`.url`/`.unknown` — but it never fetches the bytes; you load `previewImageUrl`/`contentUrl` yourself (the caching + tap-to-retry below is app code, not the SDK).

```swift
func configure(with attachments: [Attachment]) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    isHidden = attachments.isEmpty
    for attachment in attachments { stack.addArrangedSubview(makeCard(for: attachment)) }
}
```

*See [Build your own UI › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### URL cards — second `AttachmentCarouselView`

`MessageCell` filters the agent message into two attachment groups and feeds each to its own carousel — `.image` to `carousel`, `.url` to `urlCarousel`. URL link-cards reuse the same card as images (preview on top, title + CTA below; the preview falls back to `previewImageUrl ?? contentUrl`). Tap opens `contentUrl`.

**Under the hood:** same decoded `Attachment` data — the SDK hands you the `.url`'s `previewImageUrl`, `contentUrl`, and title, and leaves the card layout and link-opening entirely to your code.

```swift
carousel.configure(with: m.attachments.filter { $0.contentType == .image })
urlCarousel.configure(with: m.attachments.filter { $0.contentType == .url })
```

(`URLCardView.swift` is also in this folder as a more compact, single-row card — copy it instead if you prefer a vertical list of link cards over a horizontal carousel.)

*See [Build your own UI › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Call actions — `CallActionsRow.swift`

Each `ChatCallAction` becomes a filled green button. Tap opens `tel:` with non-digit characters stripped from the contact number.

**Under the hood:** each `ChatCallAction` is just decoded data — a `title` and a `contactNumber`. The SDK never dials; building the `tel:` URL and opening it is your code.

```swift
let digits = action.contactNumber.filter { $0.isNumber || $0 == "+" }
guard let url = URL(string: "tel:\(digits)") else { return }
UIApplication.shared.open(url)
```

*See [Build your own UI › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Retryable images — `RetryableImageView.swift`

A `UIImageView` subclass that loads via `URLSession` with a small `NSCache`, a centered activity indicator, tap-to-retry on failure, and a one-shot auto-retry after 5s. On failure it shows the supplied `fallback` image.

**Under the hood:** the SDK plays no part here — it only gave you the image URLs. All loading, caching, and retry behaviour lives in this app-side view, so you can swap in whatever image stack you prefer.

```swift
func load(url: URL?, fallback: UIImage? = nil) {
    task?.cancel(); image = nil; fallbackImage = fallback; currentURL = url
    guard let url else { image = fallback; return }
    if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
    activity.startAnimating()
    task = URLSession.shared.dataTask(with: URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)) { [weak self] data, _, _ in
        DispatchQueue.main.async {
            self?.activity.stopAnimating()
            guard self?.currentURL == url else { return }
            if let data, let img = UIImage(data: data) { Self.cache.setObject(img, forKey: url as NSURL); self?.image = img }
            else { self?.image = self?.fallbackImage; self?.scheduleAutoRetry(for: url) }
        }
    }
    task?.resume()
}
```

### Markdown + tappable links — `MessageCell`

The most important detail here is the **bubble's text view, not its text**. The agent
bubble renders into a **non-editable `UITextView`** (named `label` in the cell, but it
is a `UITextView`) — *not* a `UILabel`. That's deliberate: a `UILabel` shows `.link`
styling but ignores taps, so Markdown links would look right and do nothing. A
`UITextView` makes them tappable and opens `http`/`https` links in Safari for free. It's
configured once in `init` — `isEditable = false`, `isScrollEnabled = false` (so it
self-sizes in the cell, with zeroed insets), and `linkTextAttributes` for the
blue/underline style:

```swift
label.isEditable = false
label.isScrollEnabled = false
label.linkTextAttributes = [.foregroundColor: UIColor.systemBlue,
                            .underlineStyle: NSUnderlineStyle.single.rawValue]
```

`applyMarkdown(_:)` then parses the text with iOS 15+ `AttributedString(markdown:)` for
bold/italic/`code`/`[links](url)`, falling back to plain text on parse failure —
streaming chunks can carry half-open markdown (e.g. a trailing `**`), and we keep them
readable until the next chunk lands:

```swift
let options = AttributedString.MarkdownParsingOptions(
    interpretedSyntax: .inlineOnlyPreservingWhitespace
)
if let attr = try? AttributedString(markdown: text, options: options) {
    let ns = NSMutableAttributedString(attributedString: NSAttributedString(attr))
    ns.addAttribute(.font, value: UIFont.systemFont(ofSize: 15), range: NSRange(location: 0, length: ns.length))
    ns.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: ns.length))
    label.attributedText = ns          // links are now tappable (UITextView, not UILabel)
} else {
    label.text = text
}
```

**Under the hood:** `AgentMessage.text` is the agent's raw Markdown, passed through untouched (there's no HTML to sanitize) — rendering it is your job. While a reply streams, that text grows and can briefly hold half-open Markdown, which is why the parse-failure fallback to plain text matters.

> `AttributedString(markdown:)` links `[text](url)` but **not** bare `https://…` URLs. The
> SwiftUI counterpart's [`RichText`](../../SwiftUI/03-RichContent/Components/RichText.swift)
> adds a small regex pass for bare URLs — port it if your agent emits them.

*See [Build your own UI › Rich text & links](../../../README.md#rich-text--links).*

> **Streaming:** these chunks render as a completed bubble by default. To show agent replies growing live as they stream in, enable `progressiveStreaming` — see [07-Playground](../07-Playground/) and the root README's [*Streaming*](../../../README.md#streaming) section.

### Bubble layout — `MessageCell.swift`

The cell's `outerStack` lays out text → image carousel → URL link-cards → call actions in that order. `.unknown` attachment types are dropped silently for forward-compat.

**Under the hood:** the SDK groups everything onto one assembled agent message — text, attachments, and call actions all arrive together; `.unknown` is the SDK's forward-compat slot for content types it doesn't model yet, so dropping it is the safe default.

## What this example skips

- offline detection, loading skeleton, terminal error → [`../04-Resilience/`](../04-Resilience/)
- live agent handoff → [`../05-Handoff/`](../05-Handoff/)

## Copy these into your app

The views in this folder use only **public SDK types** (`ChatMessage`, `Attachment`, `ChatCallAction`, …), so they drop into any app that has the package. Add the package (root [README → Install](../../../README.md#install)) and drive these views from `ChatSession` — full walkthrough in root [README → "Build your own UI"](../../../README.md#build-your-own-ui).

---

SwiftUI counterpart: [`Examples/SwiftUI/03-RichContent/`](../../SwiftUI/03-RichContent/).

When you change this example, update the matching snippets in the project [`README.md`](../../../README.md) **and** the SwiftUI counterpart. See `SKILL.md §12`.
