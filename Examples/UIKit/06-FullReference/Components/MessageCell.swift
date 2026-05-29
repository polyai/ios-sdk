// Copyright PolyAI Limited

//  MessageCell.swift
//  Examples/UIKit/06-FullReference
//
//  Renders a single ChatMessage. Agent bubbles support rich content
//  (attachments, URL cards, call actions) and switch on AgentKind so
//  live-agent bubbles get a distinct teal style. System rows render as
//  centered pills, level-styled, with handoff routes as tappable links —
//  mirroring the SwiftUI 06 MessageBubbleView.
//
//  Unlike L05, the user "Sending..." caption is gated behind `showSendingLabel`
//  so fast confirmations don't flash it (the 500ms delay lives in the
//  view controller).
//

import UIKit
import PolyMessaging

final class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    /// Closure invoked when the user taps the retry indicator on a failed message.
    var onRetry: ((String) -> Void)?

    private let outerStack = UIStackView()
    private let captionLabel = UILabel()
    private let bubbleRow = UIStackView()
    private let retryButton = UIButton(type: .system)
    private let avatarView = RetryableImageView()
    private let bubble = UIView()
    private let textLabel_ = UITextView()   // a text view (not a label) so Markdown links are tappable
    private let attachmentsView = AttachmentCarouselView()      // image attachments
    private let urlCarousel = AttachmentCarouselView()          // URL link-cards (same card, horizontal)
    private let callActionsRow = CallActionsRow()
    private let deliveryLabel = UILabel()

    private var failedText: String?
    private var systemTapURL: URL?

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
        // the insets are zeroed so the bubble's own padding applies. Interaction is
        // enabled only on agent rows (see configureAgent) — system rows keep it off so
        // the bubble's tap gesture still opens handoff routes via systemTapURL.
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
        bubble.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bubbleTapped)))

        // URL link-cards render in their own horizontal carousel (side by side,
        // scrolls) — same fill-width treatment as the image carousel.
        outerStack.addArrangedSubview(urlCarousel)

        outerStack.addArrangedSubview(attachmentsView)
        outerStack.addArrangedSubview(callActionsRow)

        deliveryLabel.font = .systemFont(ofSize: 11)
        deliveryLabel.textColor = .secondaryLabel
        deliveryLabel.textAlignment = .right
        outerStack.addArrangedSubview(deliveryLabel)

        leadingConstraint = outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        centerConstraint = outerStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            outerStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),
        ])

        // Rich-content rows (carousels, call buttons) are scroll/fill containers
        // with no intrinsic width. In the leading-aligned outerStack they otherwise
        // collapse to zero width — invisible, yet still reserving their fixed height
        // (e.g. the 220pt carousel left a blank gap above the suggestions). Give them
        // a definite content width so they actually show.
        //
        // The two carousels use an optional priority (.required - 1) so the pin
        // yields to the stack's hide-collapse when the message has no attachments
        // of that kind — letting the cards show side by side AND fully collapse
        // when empty. The call-action row keeps a plain required pin.
        let attachmentsWidth = attachmentsView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        attachmentsWidth.priority = .required - 1
        attachmentsWidth.isActive = true

        let urlCarouselWidth = urlCarousel.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85)
        urlCarouselWidth.priority = .required - 1
        urlCarouselWidth.isActive = true

        NSLayoutConstraint.activate([
            callActionsRow.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.85),
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
        systemTapURL = nil
        onRetry = nil
        avatarView.load(url: nil)
        avatarView.layer.borderWidth = 0
        avatarView.layer.borderColor = nil
    }

    func configure(with message: ChatMessage, showSendingLabel: Bool = false) {
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
        bubble.isHidden = false
        bubble.layer.borderWidth = 0
        bubble.layer.borderColor = nil
        bubble.layer.cornerRadius = 18
        avatarView.layer.borderWidth = 0
        avatarView.layer.borderColor = nil
        textLabel_.font = .systemFont(ofSize: 15)
        textLabel_.isUserInteractionEnabled = false   // only agent rows enable link taps (set in configureAgent)
        systemTapURL = nil

        switch message {
        case .user(let m):
            configureUser(m, showSendingLabel: showSendingLabel)
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

    private func configureUser(_ m: UserMessage, showSendingLabel: Bool) {
        textLabel_.text = m.text
        switch m.delivery {
        case .pending:
            textLabel_.textColor = .white
            bubble.backgroundColor = .systemBlue
            if showSendingLabel {
                deliveryLabel.isHidden = false
                deliveryLabel.text = "Sending..."
                deliveryLabel.textColor = .secondaryLabel
            }
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
                    attr.addAttribute(.foregroundColor, value: UIColor.systemTeal, range: NSRange(range, in: full))
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
            textLabel_.attributedText = Self.renderMarkdown(m.text)
            textLabel_.textColor = .label
            textLabel_.isUserInteractionEnabled = true   // make Markdown links tappable in agent bubbles
            bubble.backgroundColor = isLive ? UIColor.systemTeal.withAlphaComponent(0.18) : .systemGray5
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
        textLabel_.font = .systemFont(ofSize: 12)
        bubble.layer.cornerRadius = 14

        if case .handoffRequired(let route) = m.event {
            configureHandoffRequired(route: route)
            return
        }

        let style = levelStyle(for: m.event)
        textLabel_.text = systemText(for: m.event)
        textLabel_.textColor = style.foreground
        bubble.backgroundColor = style.background
    }

    private func configureHandoffRequired(route: String) {
        if let url = URL(string: route), url.scheme?.hasPrefix("http") == true {
            systemTapURL = url
            textLabel_.text = route
            textLabel_.textColor = .systemBlue
            bubble.backgroundColor = .systemGray6
        } else {
            textLabel_.text = route.isEmpty ? "Contact Support" : "Contact Support: \(route)"
            textLabel_.textColor = .secondaryLabel
            bubble.backgroundColor = .systemGray6
        }
    }

    @objc private func bubbleTapped() {
        guard let url = systemTapURL else { return }
        UIApplication.shared.open(url)
    }

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

    private static func renderMarkdown(_ rawText: String) -> NSAttributedString {
        let text = normalizeAgentHTML(rawText)
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
        case .agentLeft, .liveAgentLeft: return ""
        case .liveAgentJoined(let name): return "Connected with \(name ?? "an agent")"
        case .queueStatus(let position, let displayMessage):
            return displayMessage ?? "Queue position: \(position ?? 0)"
        case .handoffStarted: return "Transferring you to an agent..."
        case .handoffRequired(let reason): return "Transfer required: \(reason)"
        case .handoffAccepted: return "An agent will be with you shortly"
        case .handoffFailed(let reason): return "Transfer failed: \(reason ?? "unknown")"
        case .handoffTimeout: return "Transfer timed out"
        case .idleWarning: return "Session will expire soon"
        case .serverMessage(let text, _): return text
        }
    }

    private struct LevelStyle { let foreground: UIColor; let background: UIColor }

    private func levelStyle(for event: SystemEvent) -> LevelStyle {
        switch event {
        case .serverMessage(_, let level):
            switch level {
            case .info: return LevelStyle(foreground: .secondaryLabel, background: .systemGray6)
            case .warning: return LevelStyle(foreground: .systemOrange, background: UIColor.systemOrange.withAlphaComponent(0.12))
            case .error: return LevelStyle(foreground: .systemRed, background: UIColor.systemRed.withAlphaComponent(0.12))
            }
        case .handoffFailed, .handoffTimeout:
            return LevelStyle(foreground: .systemRed, background: UIColor.systemRed.withAlphaComponent(0.12))
        case .idleWarning:
            return LevelStyle(foreground: .systemOrange, background: UIColor.systemOrange.withAlphaComponent(0.12))
        default:
            return LevelStyle(foreground: .secondaryLabel, background: .systemGray6)
        }
    }
}
