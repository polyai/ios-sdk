//  MessageCell.swift
//  Examples/UIKit/04-Resilience
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//    - § "What you can build > Delivery tracking"
//
//  Renders a single ChatMessage. User bubbles trail-align with an inline
//  retry button on .failed delivery and "Sending..."/"Tap to retry" caption.
//  Agent bubbles lead-align with a circular avatar, agent name caption,
//  optional markdown text, an attachment carousel, and call-action buttons.
//  System messages centre as a capsule pill.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

final class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    // Outer vertical stack:
    //   [agent name caption] -> [bubble row] -> [carousel] -> [callActions] -> [delivery caption]
    private let outerStack = UIStackView()
    private let captionLabel = UILabel()
    private let bubbleRow = UIStackView()
    private let retryButton = UIButton(type: .system)
    private let avatarView = RetryableImageView()
    private let bubble = UIView()
    private let textLabel_ = UITextView()   // a text view (not a label) so Markdown links are tappable
    private let attachmentCarousel = AttachmentCarouselView()   // image attachments
    private let urlCarousel = AttachmentCarouselView()          // URL link-cards (same card, horizontal)
    private let callActionsRow = CallActionsRow()
    private let deliveryLabel = UILabel()

    private var failedText: String?
    private var onRetry: ((String) -> Void)?

    // Three competing horizontal constraints — exactly one is activated per configure().
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var centerConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.axis = .vertical
        outerStack.spacing = 6
        outerStack.alignment = .leading
        contentView.addSubview(outerStack)

        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabel
        outerStack.addArrangedSubview(captionLabel)

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
        // the insets are zeroed so the bubble's own padding applies. linkTextAttributes
        // styles .link ranges and the text view opens them on tap.
        textLabel_.translatesAutoresizingMaskIntoConstraints = false
        textLabel_.isEditable = false
        textLabel_.isScrollEnabled = false
        textLabel_.backgroundColor = .clear
        textLabel_.textContainerInset = .zero
        textLabel_.textContainer.lineFragmentPadding = 0
        textLabel_.font = .systemFont(ofSize: 15)
        textLabel_.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        bubble.addSubview(textLabel_)

        // Image attachments render in a horizontal carousel (side by side,
        // scrolls). The 0.85 width pin fills the agent content width so cards
        // show side by side rather than the one-card default width; the optional
        // priority lets it yield to the stack's hide-collapse when empty/hidden.
        outerStack.addArrangedSubview(attachmentCarousel)
        let attachmentCarouselWidth = attachmentCarousel.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        attachmentCarouselWidth.priority = .required - 1
        attachmentCarouselWidth.isActive = true

        // URL link-cards render in their own horizontal carousel (side by side,
        // scrolls) — same fill-width treatment as the image carousel.
        outerStack.addArrangedSubview(urlCarousel)
        let urlCarouselWidth = urlCarousel.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        urlCarouselWidth.priority = .required - 1
        urlCarouselWidth.isActive = true

        outerStack.addArrangedSubview(callActionsRow)

        deliveryLabel.font = .systemFont(ofSize: 11)
        deliveryLabel.isHidden = true
        outerStack.addArrangedSubview(deliveryLabel)

        leadingConstraint = outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        centerConstraint = outerStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            outerStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),

            // Bubble inner padding 14h / 10v.
            textLabel_.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            textLabel_.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            textLabel_.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            textLabel_.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        textLabel_.attributedText = nil
        textLabel_.text = nil
        attachmentCarousel.configure(with: [])
        urlCarousel.configure(with: [])
        callActionsRow.isHidden = true
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
        attachmentCarousel.configure(with: [])
        urlCarousel.configure(with: [])
        callActionsRow.isHidden = true
        bubble.isHidden = false
        bubble.layer.cornerRadius = 18
        textLabel_.font = .systemFont(ofSize: 15)
        self.onRetry = onRetry

        switch message {
        case .user(let m):
            textLabel_.text = m.text
            let failed = (m.delivery == .failed)
            if failed {
                bubble.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
                textLabel_.textColor = .label
                retryButton.isHidden = false
                failedText = m.text
                deliveryLabel.isHidden = false
                deliveryLabel.text = "Tap to retry"
                deliveryLabel.textColor = .systemRed
            } else {
                bubble.backgroundColor = .systemBlue
                textLabel_.textColor = .white
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
            // Markdown rendering with plain-text fallback.
            if !m.text.isEmpty {
                textLabel_.attributedText = Self.renderMarkdown(m.text)
                bubble.isHidden = false
            } else {
                bubble.isHidden = true
            }
            textLabel_.textColor = .label
            bubble.backgroundColor = .systemGray5
            avatarView.isHidden = false
            avatarView.load(url: m.avatarUrl, fallback: UIImage(systemName: "person.circle.fill"))
            if let name = m.agentName, !name.isEmpty {
                captionLabel.isHidden = false
                captionLabel.text = name
            }

            // Image attachments → image carousel; URL link-cards → their own
            // carousel (same card, also horizontal/side-by-side).
            attachmentCarousel.configure(with: m.attachments.filter { $0.contentType == .image })
            urlCarousel.configure(with: m.attachments.filter { $0.contentType == .url })
            // `.unknown` attachments are intentionally dropped — forward-compat
            // for new attachment kinds the SDK may add.

            if !m.callActions.isEmpty {
                callActionsRow.configure(actions: m.callActions)
                callActionsRow.isHidden = false
            }

            leadingConstraint.isActive = true
            outerStack.alignment = .leading
            bubbleRow.alignment = .top

        case .system(let m):
            textLabel_.text = systemText(for: m.event)
            textLabel_.textColor = .secondaryLabel
            textLabel_.font = .systemFont(ofSize: 12)
            // Capsule pill bg systemGray6, corner 14.
            bubble.backgroundColor = .systemGray6
            bubble.layer.cornerRadius = 14
            centerConstraint.isActive = true
            outerStack.alignment = .center
            bubbleRow.alignment = .center
        }
    }

    private static func renderMarkdown(_ text: String) -> NSAttributedString {
        // iOS 15+ markdown initialiser. .inlineOnlyPreservingWhitespace
        // keeps newlines + spacing while still parsing inline emphasis.
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: text, options: opts) {
            let ns = NSMutableAttributedString(attributedString: NSAttributedString(attr))
            let range = NSRange(location: 0, length: ns.length)
            ns.addAttribute(.font, value: UIFont.systemFont(ofSize: 15), range: range)
            ns.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            return ns
        }
        return NSAttributedString(string: text)
    }

    private func systemText(for event: SystemEvent) -> String {
        switch event {
        case .conversationEnded:            return "Conversation ended"
        case .agentLeft:                    return "Agent left"
        case .liveAgentJoined(let name):    return "\(name ?? "An agent") joined"
        case .liveAgentLeft:                return "Live agent left"
        case .handoffStarted:               return "Transferring to a live agent…"
        case .handoffRequired(let reason):  return "Handoff: \(reason)"
        case .handoffAccepted:              return "Connected to live agent"
        case .handoffFailed(let reason):    return "Handoff failed: \(reason ?? "unknown")"
        case .handoffTimeout:               return "No agents available"
        case .queueStatus(let pos, let msg):
            if let msg = msg { return msg }
            return pos.map { "Position #\($0) in queue" } ?? "Queued…"
        case .idleWarning:                  return "Session will close due to inactivity"
        case .serverMessage(let text, _):   return text
        }
    }
}
