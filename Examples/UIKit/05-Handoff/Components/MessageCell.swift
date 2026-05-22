//  MessageCell.swift
//  Examples/UIKit/05-Handoff
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//    - § "What you can build > Live agent handoff"
//
//  Renders a single ChatMessage. Agent bubbles support rich content
//  (attachments, URL cards, call actions) and switch on AgentKind so
//  live-agent bubbles get a distinct teal style + "· live agent" caption
//  + a teal ring around the avatar.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

final class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    /// Closure invoked when the user taps the retry indicator on a failed message.
    var onRetry: ((String) -> Void)?

    // Outer vertical stack:
    //   [agent name caption] -> [bubble row] -> [url carousel] -> [image carousel] -> [callActions] -> [delivery caption]
    private let outerStack = UIStackView()
    private let captionLabel = UILabel()
    private let bubbleRow = UIStackView()
    private let retryButton = UIButton(type: .system)
    private let avatarView = RetryableImageView()
    private let bubble = UIView()
    private let textLabel_ = UITextView()   // a text view (not a label) so Markdown links are tappable
    private let attachmentsView = AttachmentCarouselView()   // image attachments
    private let urlCarousel = AttachmentCarouselView()       // URL link-cards (same card, horizontal)
    private let callActionsRow = CallActionsRow()
    private let deliveryLabel = UILabel()

    private var failedText: String?

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

        captionLabel.font = .systemFont(ofSize: 11, weight: .medium)
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
            if let text = self?.failedText { self?.onRetry?(text) }
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
        NSLayoutConstraint.activate([
            textLabel_.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            textLabel_.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            textLabel_.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            textLabel_.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])

        // URL link-cards render in their own horizontal carousel (side by side,
        // scrolls) — same fill-width treatment as the image carousel.
        outerStack.addArrangedSubview(urlCarousel)
        let urlCarouselWidth = urlCarousel.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        urlCarouselWidth.priority = .required - 1
        urlCarouselWidth.isActive = true

        outerStack.addArrangedSubview(attachmentsView)
        // Let the carousel fill the agent content width so image cards show
        // side by side and scroll horizontally (SwiftUI parity), rather than
        // the one-card default width. Optional priority so it yields to the
        // stack's hide-collapse when the message has no image attachments.
        let attachmentsWidth = attachmentsView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        attachmentsWidth.priority = .required - 1
        attachmentsWidth.isActive = true

        outerStack.addArrangedSubview(callActionsRow)

        deliveryLabel.font = .systemFont(ofSize: 11)
        deliveryLabel.textColor = .secondaryLabel
        deliveryLabel.textAlignment = .right
        outerStack.addArrangedSubview(deliveryLabel)

        // Three competing position constraints — exactly one is activated per configure().
        leadingConstraint = outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        centerConstraint = outerStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            outerStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        attachmentsView.configure(with: [])
        urlCarousel.configure(with: [])
        textLabel_.attributedText = nil
        textLabel_.text = nil
        failedText = nil
        onRetry = nil
        avatarView.load(url: nil)
        // Clear avatar ring.
        avatarView.layer.borderWidth = 0
        avatarView.layer.borderColor = nil
    }

    func configure(with message: ChatMessage) {
        // Reset alignment + visibility defaults.
        leadingConstraint.isActive = false
        trailingConstraint.isActive = false
        centerConstraint.isActive = false

        captionLabel.isHidden = true
        retryButton.isHidden = true
        avatarView.isHidden = true
        callActionsRow.isHidden = true
        deliveryLabel.isHidden = true
        // The two carousels own their own `isHidden` inside `configure(with:)`
        // (guarded so it's set at most once). Do NOT also toggle it directly
        // here: setting an arranged subview's isHidden to the same value twice
        // in one pass corrupts UIStackView's hidden bookkeeping, leaving the
        // carousel stuck hidden — the cell then sizes to its text only and the
        // image card spills over the rows below it.
        attachmentsView.configure(with: [])
        urlCarousel.configure(with: [])
        bubble.layer.borderWidth = 0
        bubble.layer.borderColor = nil
        bubble.layer.cornerRadius = 18
        avatarView.layer.borderWidth = 0
        avatarView.layer.borderColor = nil
        textLabel_.font = .systemFont(ofSize: 15)

        switch message {
        case .user(let m):
            configureUser(m)
            trailingConstraint.isActive = true
            outerStack.alignment = .trailing
            bubbleRow.alignment = .bottom

        case .agent(let m):
            configureAgent(m)
            leadingConstraint.isActive = true
            outerStack.alignment = .leading
            bubbleRow.alignment = .top

        case .system(let m):
            configureSystem(m)
            centerConstraint.isActive = true
            outerStack.alignment = .center
            bubbleRow.alignment = .center
        }
    }

    // MARK: - User

    private func configureUser(_ m: UserMessage) {
        textLabel_.text = m.text
        switch m.delivery {
        case .pending:
            textLabel_.textColor = .white
            bubble.backgroundColor = .systemBlue
            deliveryLabel.isHidden = false
            deliveryLabel.text = "Sending..."
            deliveryLabel.textColor = .secondaryLabel
        case .sent:
            textLabel_.textColor = .white
            bubble.backgroundColor = .systemBlue
        case .failed:
            textLabel_.textColor = .label
            bubble.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
            retryButton.isHidden = false
            failedText = m.text
            deliveryLabel.isHidden = false
            deliveryLabel.text = "Tap to retry"
            deliveryLabel.textColor = .systemRed
        }
    }

    // MARK: - Agent

    private func configureAgent(_ m: AgentMessage) {
        let isLive = (m.agentKind == .live)

        avatarView.isHidden = false
        avatarView.load(url: m.avatarUrl, fallback: UIImage(systemName: "person.circle.fill"))
        if isLive {
            // Teal ring around the avatar for live-agent messages.
            avatarView.layer.borderWidth = 1.5
            avatarView.layer.borderColor = UIColor.systemTeal.cgColor
        }

        if let name = m.agentName, !name.isEmpty {
            captionLabel.isHidden = false
            if isLive {
                let full = "\(name) · live agent"
                let attr = NSMutableAttributedString(string: full,
                                                     attributes: [.foregroundColor: UIColor.secondaryLabel,
                                                                  .font: UIFont.systemFont(ofSize: 11, weight: .medium)])
                if let range = full.range(of: " · live agent") {
                    let ns = NSRange(range, in: full)
                    attr.addAttribute(.foregroundColor, value: UIColor.systemTeal, range: ns)
                }
                captionLabel.attributedText = attr
            } else {
                captionLabel.attributedText = nil
                captionLabel.text = name
                captionLabel.textColor = .secondaryLabel
            }
        }

        if m.text.isEmpty {
            bubble.isHidden = true
        } else {
            bubble.isHidden = false
            textLabel_.attributedText = Self.renderMarkdown(m.text)
            textLabel_.textColor = .label
            if isLive {
                bubble.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.18)
            } else {
                bubble.backgroundColor = .systemGray5
            }
        }

        // Image attachments → image carousel; URL link-cards → their own
        // carousel (same card, also horizontal/side-by-side).
        // Each carousel's `configure(with:)` shows/hides itself (guarded) based
        // on whether it has content — see the note in `configure(with:)`.
        let images = m.attachments.filter { $0.contentType == .image }
        let urls = m.attachments.filter { $0.contentType == .url }

        attachmentsView.configure(with: images)
        urlCarousel.configure(with: urls)
        if !m.callActions.isEmpty {
            callActionsRow.isHidden = false
            callActionsRow.configure(actions: m.callActions)
        }
    }

    // MARK: - System

    private func configureSystem(_ m: SystemMessage) {
        let text = systemText(for: m.event)
        bubble.isHidden = false
        textLabel_.text = text
        textLabel_.textColor = .secondaryLabel
        textLabel_.font = .systemFont(ofSize: 12)
        // Capsule pill bg systemGray6, corner 14.
        bubble.backgroundColor = .systemGray6
        bubble.layer.cornerRadius = 14
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
        case .conversationEnded: return "This conversation has ended"
        case .agentLeft: return "Agent left"
        case .liveAgentJoined(let name): return "\(name ?? "An agent") joined"
        case .liveAgentLeft: return "Agent left"
        case .queueStatus(let position, let displayMessage):
            if let displayMessage, !displayMessage.isEmpty { return displayMessage }
            return position.map { "Position #\($0) in queue" } ?? "Queued..."
        case .handoffStarted: return "Transferring to a live agent..."
        case .handoffRequired(let reason): return reason.isEmpty ? "Switching support channel" : "Switching to \(reason)"
        case .handoffAccepted: return "An agent will be with you shortly"
        case .handoffFailed(let reason): return reason.map { "Transfer failed: \($0)" } ?? "Transfer failed"
        case .handoffTimeout: return "No agents available"
        case .idleWarning: return "Session will expire soon"
        case .serverMessage(let text, _): return text
        }
    }
}
