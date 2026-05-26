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

In a view controller — call from `cellForRowAt`; the cell hosts a horizontal stack of `UIImageView`s:

```swift
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    cell.imageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }   // clear on reuse
    guard case .agent(let m) = session.messages[indexPath.row] else { return cell }

    cell.messageLabel.text = m.text

    for att in m.attachments where att.contentType == .image {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 220).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 140).isActive = true
        if let url = att.contentUrl {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { iv.image = image }
            }.resume()
        }
        cell.imageStack.addArrangedSubview(iv)
    }
    return cell
}
```

<details>
<summary>Show <code>MessageCell</code> (subviews + constraints)</summary>

```swift
final class MessageCell: UITableViewCell {
    let messageLabel = UILabel()
    let imageStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        messageLabel.numberOfLines = 0
        imageStack.axis = .horizontal
        imageStack.spacing = 10

        let outer = UIStackView(arrangedSubviews: [messageLabel, imageStack])
        outer.axis = .vertical
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            outer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            outer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            outer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

**Under the hood:** the SDK decodes the agent's `attachments` array from the protocol payload and groups them onto the same `AgentMessage` as the text. No background fetch happens — you load `contentUrl` / `previewImageUrl` yourself. `URLSession + DispatchQueue.main.async { iv.image = ... }` is the minimum; the example's `RetryableImageView` adds caching + tap-to-retry on failure.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render URL link cards — same `attachments`, filtered by `.url`

What the SDK gives you:

```swift
att.contentUrl         // URL? — destination link
att.previewImageUrl    // URL? — preview image (often present; falls back to contentUrl)
att.title              // String? — card headline
att.callToActionText   // String? — button label, e.g. "Learn more"
```

In a view controller — render in a second horizontal stack on the cell. Tap opens `contentUrl`:

```swift
for att in m.attachments where att.contentType == .url {
    let button = UIButton(configuration: .plain())
    if let title = att.title { button.setTitle(title, for: .normal) }
    button.addAction(UIAction { _ in
        if let url = att.contentUrl { UIApplication.shared.open(url) }
    }, for: .touchUpInside)
    cell.urlStack.addArrangedSubview(button)
}
```

**Under the hood:** same decoded `Attachment` data — the SDK hands you the URL + preview + title, and leaves the card layout and link-opening entirely to your code. The example's full card view (`URLCardView` / `AttachmentCarouselView`) layers the preview image on top of the title + CTA; the snippet above shows the minimum tappable element.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render `tel:` call buttons — `AgentMessage.callActions`

What the SDK gives you:

```swift
m.callActions   // [ChatCallAction] — agent messages only. Each:
                //   title          — String — button label, e.g. "Call now"
                //   contactNumber  — String — may be display-formatted ("+1 (555) 123-4567")
                // The SDK never dials — you build the tel: URL and open it.
```

In a view controller — render each `callAction` as a button on the cell:

```swift
for action in m.callActions {
    let button = UIButton(type: .system)
    button.setTitle("\(action.title) · \(action.contactNumber)", for: .normal)
    button.addAction(UIAction { _ in
        // Strip non-digits (keep leading +) so display-formatted numbers still produce a valid URL.
        let digits = action.contactNumber.filter { $0.isNumber || $0 == "+" }
        if let url = URL(string: "tel:\(digits)") { UIApplication.shared.open(url) }
    }, for: .touchUpInside)
    cell.callsStack.addArrangedSubview(button)
}
```

**Under the hood:** the SDK delivers `ChatCallAction` as decoded data — `title` + `contactNumber`. Dialling is your code: sanitise the number (digits + leading `+`), build `tel:<digits>`, hand to `UIApplication.shared.open`.

*See [Integration guide › Attachments, link cards & call buttons](../../../README.md#attachments-link-cards--call-buttons).*

### Render Markdown (tappable links) — `AgentMessage.text`

What the SDK gives you:

```swift
m.text   // String — the agent's raw Markdown (no HTML; nothing to sanitize).
         // Grows in place during streaming and can briefly hold half-open Markdown
         // (e.g. a trailing `**` waiting for its closer) — your parser should tolerate that.
```

**The most important detail: use a `UITextView`, not a `UILabel`.** A `UILabel` *renders* `.link` styling but ignores taps. A `UITextView` makes them tappable and opens `http`/`https` links in Safari for free.

In a view controller — configure once in the cell's `init`, then call from `cellForRowAt`:

```swift
func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
    guard case .agent(let m) = session.messages[indexPath.row] else { return cell }

    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attr = try? AttributedString(markdown: m.text, options: opts) {
        cell.textView.attributedText = NSAttributedString(attr)
    } else {
        cell.textView.text = m.text       // fall back to plain text during half-open Markdown
    }
    return cell
}
```

<details>
<summary>Show <code>MessageCell</code> with tappable-link <code>UITextView</code></summary>

```swift
final class MessageCell: UITableViewCell {
    let textView = UITextView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        textView.isEditable = false
        textView.isScrollEnabled = false          // self-sizes in the cell
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
```

</details>

> `AttributedString(markdown:)` links `[text](url)` but **not** bare `https://…` URLs. The SwiftUI counterpart's `RichText` adds a small regex pass for bare URLs — port it if your agent emits them.

**Under the hood:** the SDK passes the agent's Markdown through untouched. Streaming chunks update `m.text` in place; the parse-failure fallback to plain text keeps the bubble readable mid-stream until the next chunk lands.

*See [Integration guide › Rich text & links](../../../README.md#rich-text--links).*

### Bubble layout — compose everything

The cell's outer stack lays out text → image carousel → URL link-cards → call actions in that order. `.unknown` attachment types are dropped silently for forward-compat.

```swift
// MessageCell init:
let outer = UIStackView(arrangedSubviews: [textView, imageStack, urlStack, callsStack])
outer.axis = .vertical
outer.spacing = 8
```

Each subview hides itself when the message has nothing to put in it (you can either toggle `isHidden` based on counts, or use `UIStackView`'s `arrangedSubviews.isEmpty` semantics).

**Under the hood:** the SDK delivers text, attachments, and call actions on one assembled `AgentMessage` — no separate events to coordinate. `.unknown` is the SDK's forward-compat slot for content types it doesn't model yet; dropping it (instead of falling through to a placeholder) is the safe default.

## What this example skips

- offline detection, loading skeleton, full-screen terminal error → [`04-Resilience/`](../04-Resilience/)
- live agent handoff → [`05-Handoff/`](../05-Handoff/)

---

- **SwiftUI counterpart:** [`Examples/SwiftUI/03-RichContent/`](../../SwiftUI/03-RichContent/)
- **SDK reference:** root [README → Integration guide](../../../README.md#integration-guide)
- **Install the package:** root [README → Install](../../../README.md#install)
