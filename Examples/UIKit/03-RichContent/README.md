# 03-RichContent (UIKit)

Adds image attachments, URL link cards, `tel:` call actions, and Markdown rendering on top of [`02-Standard`](../02-Standard/). The UIKit twin of [`Examples/SwiftUI/03-RichContent/`](../../SwiftUI/03-RichContent/).

Setup, scaffolding, and everything inherited from 02 (typing, suggestions, delivery, reconnect, end + start-new) are unchanged — read [`02-Standard`](../02-Standard/) first. This README covers only what 03 adds.

## Run it

```bash
open RichContentUIKit.xcodeproj   # from this folder
# Cmd+R on an iPhone simulator
```

Set your connector token in `App/AppDelegate.swift` (currently `"YOUR_CONNECTOR_TOKEN"`).

## What this example demonstrates

- Image attachments — `AgentMessage.attachments` filtered by `contentType == .image`
- URL link cards — same `attachments` array filtered by `.url`
- `tel:` call buttons — `AgentMessage.callActions`
- Markdown rendering in a **`UITextView`** (not a `UILabel`) so links are tappable
- Forward-compat: drop `.unknown` content types silently

**The SDK decodes the data; it never fetches bytes or dials phones.** You own image loading, caching, retry, link-opening, and the `tel:` `URL`. This example shows one way to do all of that with stock UIKit.

The SDK invariants behind each pattern are in the root README's [Integration guide](../../../README.md#integration-guide).

## How it works

Each subsection leads with **the SDK data** (the actual API), then shows **how it's wired into the message cell**.

### Render image attachments — inside the cell's image stack

What the SDK gives you:

```swift
m.attachments   // [Attachment] — agent messages only. Each carries:
                //   contentType   — .image / .url / .unknown (drop .unknown for forward-compat)
                //   contentUrl    — URL? — where the asset lives
                //   previewImageUrl — URL? — smaller preview (often nil for raw images)
                //   title         — String? / callToActionText — String?
                // The SDK never fetches bytes — you load the URL with URLSession.
```

In a view controller — `MessageCell` owns an `AttachmentCarouselView` and just gets handed the filtered list inside `configure(with:)`. The carousel renders 220×140 cards (preview + optional title + CTA), opens `contentUrl` on tap, and hides itself when the array is empty:

```swift
// In ChatViewController — register the cell and dequeue by its real reuseID:
tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)

let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
cell.configure(with: message, onRetry: { [weak self] text in
    Task { try? await self?.session.send(text) }
}, showSendingLabel: pending)

// Inside MessageCell.configure(with:) — agent branch only:
case .agent(let m):
    applyMarkdown(m.text)                                                            // UITextView, see below
    carousel.configure(with: m.attachments.filter { $0.contentType == .image })      // image cards
    urlCarousel.configure(with: m.attachments.filter { $0.contentType == .url })     // URL link-cards (next section)
    callActions.configure(actions: m.callActions)                                    // tel: buttons (next-next section)
    // `.unknown` attachments are intentionally dropped — forward-compat
```

<details>
<summary>Show <code>MessageCell</code> outline (real property names + types)</summary>

```swift
final class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    // Outer (vertical) stack: agent name caption → bubble row → rich rows → delivery caption.
    private let outerStack = UIStackView()
    private let captionLabel = UILabel()                   // agent name
    private let bubbleRow = UIStackView()                  // [retry] [avatar] [bubble]
    private let retryButton = UIButton(type: .system)
    private let avatarView = RetryableImageView()
    private let bubble = UIView()
    private let label = UITextView()                       // a text view (not a label) so Markdown links are tappable
    private let carousel = AttachmentCarouselView()        // image attachments
    private let urlCarousel = AttachmentCarouselView()     // URL link-cards (same card, horizontal)
    private let callActions = CallActionsRow()             // green "Call ..." buttons
    private let deliveryLabel = UILabel()

    // ...init wires outerStack into contentView, sizes the carousels to 0.85× contentView.width,
    //    and applies the 14h/10v bubble padding...
}
```

</details>

**Under the hood:** the SDK decodes the agent's `attachments` array from the protocol payload and groups them onto the same `AgentMessage` as the text. No background fetch happens — `AttachmentCarouselView.makeCard` hands each `previewImageUrl ?? contentUrl` to a `RetryableImageView`, and the card itself is a `UIControl` whose `.touchUpInside` opens `contentUrl` via `UIApplication.shared.open`. Setting the carousel's `arrangedSubview.isHidden` only on a real change (`if isHidden != shouldHide`) is load-bearing — flipping it to its current value silently breaks `UIStackView`'s hidden bookkeeping and the carousel stops un-hiding.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render URL link cards — same `attachments`, filtered by `.url`

What the SDK gives you:

```swift
att.contentUrl         // URL? — destination link
att.previewImageUrl    // URL? — preview image (often present; falls back to contentUrl)
att.title              // String? — card headline
att.callToActionText   // String? — button label, e.g. "Learn more"
```

In a view controller — same `AttachmentCarouselView` as the image row, with the attachments pre-filtered to `.url`. The card lays the preview image on top of `title` + `callToActionText`, and the whole card is the tap target:

```swift
// Inside MessageCell.configure(with:) — agent branch:
urlCarousel.configure(with: m.attachments.filter { $0.contentType == .url })
```

**Under the hood:** same decoded `Attachment` data — the SDK hands you the URL + preview + title, and leaves the card layout and link-opening entirely to your code. Because the URL row reuses `AttachmentCarouselView` (it doesn't care whether the attachment came from `.image` or `.url`), you get horizontal scrolling, the same 220-wide card, and the same `UIApplication.shared.open(contentUrl)` tap target with zero extra wiring.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render `tel:` call buttons — `AgentMessage.callActions`

What the SDK gives you:

```swift
m.callActions   // [ChatCallAction] — agent messages only. Each:
                //   title          — String — button label, e.g. "Call now"
                //   contactNumber  — String — may be display-formatted ("+1 (555) 123-4567")
                // The SDK never dials — you build the tel: URL and open it.
```

In a view controller — `MessageCell` owns a `CallActionsRow` (a vertical stack of green `UIButton.Configuration.filled()` buttons). You just hand it the list:

```swift
// Inside MessageCell.configure(with:) — agent branch:
callActions.configure(actions: m.callActions)
```

`CallActionsRow.makeButton(for:)` builds each button — sanitising the number, building the `tel:` URL, wiring `.touchUpInside`:

```swift
// Components/CallActionsRow.swift — abbreviated:
private func makeButton(for action: ChatCallAction) -> UIButton {
    var config = UIButton.Configuration.filled()
    config.title = action.title.isEmpty ? action.contactNumber : action.title
    config.image = UIImage(systemName: "phone.fill")
    config.baseBackgroundColor = .systemGreen
    config.baseForegroundColor = .white

    // Strip non-digits (keep leading +) so display-formatted numbers still produce a valid URL.
    let digits = action.contactNumber.filter { $0.isNumber || $0 == "+" }
    let url = URL(string: "tel:\(digits)")

    return UIButton(configuration: config, primaryAction: UIAction { _ in
        if let url { UIApplication.shared.open(url) }
    })
}
```

**Under the hood:** the SDK delivers `ChatCallAction` as decoded data — `title` + `contactNumber`. Dialling is your code: sanitise the number (digits + leading `+`), build `tel:<digits>`, hand to `UIApplication.shared.open`. `CallActionsRow.configure(actions:)` hides the row when the array is empty so empty messages don't leave a gap.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render Markdown (tappable links) — `AgentMessage.text`

What the SDK gives you:

```swift
m.text   // String — the agent's raw Markdown (no HTML; nothing to sanitize).
         // Grows in place during streaming and can briefly hold half-open Markdown
         // (e.g. a trailing `**` waiting for its closer) — your parser should tolerate that.
```

**The most important detail: use a `UITextView`, not a `UILabel`.** A `UILabel` *renders* `.link` styling but ignores taps. A `UITextView` makes them tappable and opens `http`/`https` links in Safari for free.

In a view controller — `MessageCell` keeps a single non-editable `UITextView` named `label` and calls `applyMarkdown(m.text)` from its agent branch:

```swift
// Components/MessageCell.swift — init configures the text view ONCE:
private let label = UITextView()   // a text view (not a label) so Markdown links are tappable

override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    // ...other subview setup...
    label.isEditable = false
    label.isScrollEnabled = false               // self-sizes in the cell
    label.backgroundColor = .clear
    label.textContainerInset = .zero
    label.textContainer.lineFragmentPadding = 0
    label.font = .systemFont(ofSize: 15)
    label.linkTextAttributes = [
        .foregroundColor: UIColor.systemBlue,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    bubble.addSubview(label)
    // ...autolayout (14h/10v inside bubble)...
}

// configure(with:) — agent branch:
case .agent(let m):
    label.textColor = .label
    applyMarkdown(m.text)

// applyMarkdown(_:) — NSAttributedString(markdown:) with plain-text fallback for half-open markdown
private func applyMarkdown(_ text: String) {
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attr = try? AttributedString(markdown: text, options: opts) {
        label.attributedText = NSAttributedString(attr)
    } else {
        label.text = text       // fall back to plain text during half-open Markdown
    }
}
```

> `AttributedString(markdown:)` links `[text](url)` but **not** bare `https://…` URLs. The SwiftUI counterpart's `RichText` adds a small regex pass for bare URLs — port it if your agent emits them.

**Under the hood:** the SDK passes the agent's Markdown through untouched. Streaming chunks update `m.text` in place; the parse-failure fallback to plain text keeps the bubble readable mid-stream until the next chunk lands.

*See [Integration guide › Rich text & links](../../../README.md#rich-text--links).*

### Bubble layout — compose everything

The cell's outer stack lays out (agent name caption) → bubble row → image carousel → URL link-cards → call actions → delivery caption in that order. `.unknown` attachment types are dropped silently for forward-compat.

```swift
// MessageCell init — outerStack adds children top-to-bottom:
outerStack.axis = .vertical
outerStack.addArrangedSubview(captionLabel)    // agent name (or hidden)
outerStack.addArrangedSubview(bubbleRow)       // [retry] [avatar] [bubble(label: UITextView)]
outerStack.addArrangedSubview(carousel)        // image AttachmentCarouselView
outerStack.addArrangedSubview(urlCarousel)     // URL-card AttachmentCarouselView
outerStack.addArrangedSubview(callActions)     // CallActionsRow (tel: buttons)
outerStack.addArrangedSubview(deliveryLabel)   // "Sending..." / "Tap to retry"
```

Each component hides itself when its data is empty — `AttachmentCarouselView.configure(with:)` flips `isHidden` (carefully — `if isHidden != shouldHide` to avoid corrupting `UIStackView`'s hidden bookkeeping), and `CallActionsRow.configure(actions:)` does the same.

**Under the hood:** the SDK delivers text, attachments, and call actions on one assembled `AgentMessage` — no separate events to coordinate. `.unknown` is the SDK's forward-compat slot for content types it doesn't model yet; dropping it (instead of falling through to a placeholder) is the safe default.

## What this example skips

- offline detection, loading skeleton, full-screen terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/03-RichContent/`](../../SwiftUI/03-RichContent/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
