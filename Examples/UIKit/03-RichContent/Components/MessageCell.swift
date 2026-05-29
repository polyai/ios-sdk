// Copyright PolyAI Limited

//  MessageCell.swift
//  Examples/UIKit/03-RichContent
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//    - § "What you can build > Streaming responses"
//
//  Renders ChatMessage with a vertical stack: bubble label, image carousel,
//  URL cards, call actions. Subviews hide themselves when there's nothing to
//  show. Agent text is rendered as Markdown via NSAttributedString(markdown:)
//  with a plain-text fallback (important: streaming chunks can produce
//  half-open markdown tokens). User .failed messages render with an inline
//  retry button + caption.
//

import UIKit
import PolyMessaging

final class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    // Outer (vertical) stack: agent name caption -> bubble row -> rich rows -> delivery caption.
    private let outerStack = UIStackView()
    private let captionLabel = UILabel()          // agent name
    private let bubbleRow = UIStackView()
    private let retryButton = UIButton(type: .system)
    private let avatarView = RetryableImageView()
    private let bubble = UIView()
    private let label = UITextView()   // a text view (not a label) so Markdown links are tappable
    private let carousel = AttachmentCarouselView()      // image attachments
    private let urlCarousel = AttachmentCarouselView()   // URL link-cards (same card, horizontal)
    private let callActions = CallActionsRow()
    private let deliveryLabel = UILabel()

    private var failedText: String?
    private var onRetry: ((String) -> Void)?

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var centerConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        // Outer stack holds everything; agent rich content lives below the
        // bubble row. Width capped to 75% of contentView.
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.axis = .vertical
        outerStack.spacing = 6
        outerStack.alignment = .leading
        contentView.addSubview(outerStack)

        // Agent name caption.
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabel
        outerStack.addArrangedSubview(captionLabel)

        // Bubble row: [retry] [avatar] [bubble]
        bubbleRow.axis = .horizontal
        bubbleRow.spacing = 8
        bubbleRow.alignment = .top
        outerStack.addArrangedSubview(bubbleRow)

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        var rconf = UIButton.Configuration.plain()
        rconf.image = UIImage(systemName: "exclamationmark.circle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))
        rconf.baseForegroundColor = .systemRed
        rconf.contentInsets = .zero
        retryButton.configuration = rconf
        retryButton.addAction(UIAction { [weak self] _ in
            guard let self, let t = self.failedText else { return }
            self.onRetry?(t)
        }, for: .touchUpInside)
        bubbleRow.addArrangedSubview(retryButton)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.layer.cornerRadius = 14
        avatarView.layer.masksToBounds = true
        bubbleRow.addArrangedSubview(avatarView)
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 28),
            avatarView.heightAnchor.constraint(equalToConstant: 28),
        ])

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 18
        bubble.layer.masksToBounds = true
        bubbleRow.addArrangedSubview(bubble)

        // A non-editable UITextView (not a UILabel) so Markdown links are tappable
        // and open in Safari. isScrollEnabled = false lets it self-size in the cell;
        // the insets are zeroed so the bubble's own 14/10 padding applies. The text
        // view styles .link ranges via linkTextAttributes and opens them on tap.
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isScrollEnabled = false
        label.backgroundColor = .clear
        label.textContainerInset = .zero
        label.textContainer.lineFragmentPadding = 0
        label.font = .systemFont(ofSize: 15)
        label.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        bubble.addSubview(label)

        // Rich-content rows (below bubble row).
        outerStack.addArrangedSubview(carousel)
        // Let the carousel fill the agent content width so image cards show
        // side by side and scroll horizontally (SwiftUI parity), rather than
        // the one-card default width. Optional priority so it yields to the
        // stack's hide-collapse when the message has no image attachments.
        let carouselWidth = carousel.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        carouselWidth.priority = .required - 1
        carouselWidth.isActive = true

        // URL link-cards render in their own horizontal carousel (side by side,
        // scrolls) — same fill-width treatment as the image carousel.
        outerStack.addArrangedSubview(urlCarousel)
        let urlCarouselWidth = urlCarousel.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        urlCarouselWidth.priority = .required - 1
        urlCarouselWidth.isActive = true

        outerStack.addArrangedSubview(callActions)

        // Delivery caption.
        deliveryLabel.font = .systemFont(ofSize: 11)
        deliveryLabel.isHidden = true
        outerStack.addArrangedSubview(deliveryLabel)

        // Three competing position constraints — exactly one is active per configure().
        leadingConstraint = outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        centerConstraint = outerStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            outerStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),

            // Bubble inner padding 14h / 10v.
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        urlCarousel.configure(with: [])
        carousel.configure(with: [])
        callActions.configure(actions: [])
        label.attributedText = nil
        label.text = nil
        avatarView.load(url: nil)
        failedText = nil
        onRetry = nil
    }

    func configure(with message: ChatMessage,
                   onRetry: ((String) -> Void)? = nil,
                   showSendingLabel: Bool = false) {
        // Reset.
        leadingConstraint.isActive = false
        trailingConstraint.isActive = false
        centerConstraint.isActive = false
        retryButton.isHidden = true
        avatarView.isHidden = true
        captionLabel.isHidden = true
        deliveryLabel.isHidden = true
        bubble.isHidden = false
        bubble.layer.cornerRadius = 18

        carousel.configure(with: [])
        urlCarousel.configure(with: [])
        callActions.configure(actions: [])
        self.onRetry = onRetry

        switch message {
        case .user(let m):
            label.text = m.text
            label.font = .systemFont(ofSize: 15)
            let failed = (m.delivery == .failed)
            if failed {
                bubble.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
                label.textColor = .label
                retryButton.isHidden = false
                failedText = m.text
                deliveryLabel.isHidden = false
                deliveryLabel.text = "Tap to retry"
                deliveryLabel.textColor = .systemRed
            } else {
                bubble.backgroundColor = .systemBlue
                label.textColor = .white
                if showSendingLabel && m.delivery == .pending {
                    deliveryLabel.isHidden = false
                    deliveryLabel.text = "Sending..."
                    deliveryLabel.textColor = .secondaryLabel
                }
            }
            trailingConstraint.isActive = true
            outerStack.alignment = .trailing
            bubbleRow.alignment = .bottom

        case .agent(let m):
            label.font = .systemFont(ofSize: 15)
            label.textColor = .label
            applyMarkdown(m.text)
            bubble.backgroundColor = .systemGray5
            bubble.isHidden = m.text.isEmpty
            avatarView.isHidden = false
            avatarView.load(url: m.avatarUrl, fallback: UIImage(systemName: "person.circle.fill"))
            if let name = m.agentName, !name.isEmpty {
                captionLabel.isHidden = false
                captionLabel.text = name
            }

            // Image attachments → image carousel; URL link-cards → their own
            // carousel (same card, also horizontal/side-by-side).
            carousel.configure(with: m.attachments.filter { $0.contentType == .image })
            urlCarousel.configure(with: m.attachments.filter { $0.contentType == .url })
            // `.unknown` attachments are intentionally dropped — forward-compat
            // for new attachment kinds the SDK may add.

            callActions.configure(actions: m.callActions)
            leadingConstraint.isActive = true
            outerStack.alignment = .leading
            bubbleRow.alignment = .top

        case .system(let m):
            label.text = systemText(for: m.event)
            label.textColor = .secondaryLabel
            label.font = .systemFont(ofSize: 12)
            // Capsule pill bg systemGray6, corner 14.
            bubble.backgroundColor = .systemGray6
            bubble.layer.cornerRadius = 14
            bubble.isHidden = false
            centerConstraint.isActive = true
            outerStack.alignment = .center
            bubbleRow.alignment = .center
        }
    }

    /// Render `text` as Markdown via NSAttributedString(markdown:). Falls back
    /// to plain text on parse failure — streaming chunks may contain partial
    /// markdown that the parser rejects, and we want to keep showing them.
    /// Maps the small HTML subset the agent may emit (mirrors the web widget's
    /// DOMPurify allow-list: `a, br, b, i, em, strong, p, ul, ol, li, code`)
    /// onto newlines + Markdown. Without this, agent replies that contain
    /// literal HTML (most commonly `<br>` line breaks) render the tags raw.
    private static func normalizeAgentHTML(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var s = html
        func sub(_ pattern: String, _ replacement: String) {
            s = s.replacingOccurrences(of: pattern, with: replacement,
                                       options: [.regularExpression, .caseInsensitive])
        }
        sub(#"<a\b[^>]*\bhref=["']([^"']*)["'][^>]*>(.*?)</a>"#, "[$2]($1)")
        sub(#"<br\s*/?>"#, "\n")
        sub(#"</p\s*>"#, "\n\n"); sub(#"<p\b[^>]*>"#, "")
        sub(#"</?(?:strong|b)\b[^>]*>"#, "**")
        sub(#"</?(?:em|i)\b[^>]*>"#, "*")
        sub(#"</?code\b[^>]*>"#, "`")
        sub(#"<li\b[^>]*>"#, "\n• "); sub(#"</li\s*>"#, "")
        sub(#"</?(?:ul|ol)\b[^>]*>"#, "\n")
        sub(#"<[^>]+>"#, "")
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyMarkdown(_ rawText: String) {
        let text = Self.normalizeAgentHTML(rawText)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: text, options: options) {
            let ns = NSMutableAttributedString(attributedString: NSAttributedString(attr))
            let range = NSRange(location: 0, length: ns.length)
            ns.addAttribute(.font, value: UIFont.systemFont(ofSize: 15), range: range)
            ns.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            label.attributedText = ns
        } else {
            label.text = text
        }
    }

    private func systemText(for event: SystemEvent) -> String {
        switch event {
        case .conversationEnded:        return "Conversation ended"
        case .liveAgentJoined(let n):   return "\(n ?? "An agent") joined"
        case .liveAgentLeft:            return "Agent left"
        case .handoffStarted:           return "Transferring to a live agent…"
        case .handoffAccepted:          return "An agent will be with you shortly"
        case .handoffFailed:            return "Transfer failed"
        case .handoffTimeout:           return "No agents available"
        case .queueStatus(let pos, _):  return pos.map { "Position #\($0) in queue" } ?? "Queued…"
        case .serverMessage(let t, _):  return t
        default:                        return ""
        }
    }
}
