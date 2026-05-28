// Copyright PolyAI Limited

//  MessageCell.swift
//  Examples/UIKit/02-Standard
//
//  Renders a single ChatMessage as a bubble. User bubbles trail-align with
//  an inline retry button on .failed delivery. Agent bubbles lead-align with
//  a circular avatar + optional agent name caption. System messages render
//  as a centered capsule pill.
//

import UIKit
import PolyMessaging

final class MessageCell: UITableViewCell {
    static let reuseID = "MessageCell"

    // Outer stack holds: [name caption] -> [bubble row] -> [delivery caption]
    // The bubble row is itself a horizontal stack so we can place the retry
    // button to the LEFT of a failed user bubble or the avatar to the LEFT
    // of an agent bubble.
    private let outerStack = UIStackView()
    private let captionLabel = UILabel()                 // agent name OR delivery state
    private let bubbleRow = UIStackView()
    private let retryButton = UIButton(type: .system)    // user-only, .failed
    private let avatarView = UIImageView()               // agent-only
    private let bubble = UIView()
    private let label = UILabel()
    private let deliveryLabel = UILabel()                // "Sending..." / "Tap to retry"

    private var avatarTask: URLSessionDataTask?
    private var failedText: String?
    private var failedDraftId: String?
    private var onRetry: ((String) -> Void)?

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var centerConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        // -- outer (vertical) stack
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.axis = .vertical
        outerStack.spacing = 4
        outerStack.alignment = .leading
        contentView.addSubview(outerStack)

        // Agent name caption (above bubble row).
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabel
        outerStack.addArrangedSubview(captionLabel)

        // -- bubble row (horizontal)
        bubbleRow.axis = .horizontal
        bubbleRow.spacing = 8
        bubbleRow.alignment = .top
        outerStack.addArrangedSubview(bubbleRow)

        // Retry button (left of failed user bubble).
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

        // Avatar (left of agent bubble).
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 14
        avatarView.tintColor = .systemGray3
        bubbleRow.addArrangedSubview(avatarView)
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 28),
            avatarView.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Bubble with text.
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 18
        bubble.layer.masksToBounds = true
        bubbleRow.addArrangedSubview(bubble)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        bubble.addSubview(label)

        // Delivery caption (below bubble row).
        deliveryLabel.font = .systemFont(ofSize: 11)
        deliveryLabel.isHidden = true
        outerStack.addArrangedSubview(deliveryLabel)

        // Three competing position constraints — exactly one is activated per configure().
        leadingConstraint = outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        centerConstraint = outerStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            outerStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.85),

            // Bubble inner padding 14h / 10v (matches SwiftUI reference).
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        avatarView.image = nil
        failedText = nil
        failedDraftId = nil
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
        label.font = .systemFont(ofSize: 15)
        self.onRetry = onRetry

        switch message {
        case .user(let m):
            label.text = m.text
            let failed = (m.delivery == .failed)
            if failed {
                bubble.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
                label.textColor = .label
                retryButton.isHidden = false
                failedText = m.text
                failedDraftId = m.draftId
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
            label.text = m.text
            label.textColor = .label
            bubble.backgroundColor = .systemGray5
            avatarView.isHidden = false
            loadAvatar(url: m.avatarUrl)
            if let name = m.agentName, !name.isEmpty {
                captionLabel.isHidden = false
                captionLabel.text = name
            }
            leadingConstraint.isActive = true
            outerStack.alignment = .leading
            bubbleRow.alignment = .top

        case .system(let m):
            label.text = systemText(for: m.event)
            label.textColor = .secondaryLabel
            label.font = .systemFont(ofSize: 12)
            // Center capsule pill — bg systemGray6, corner 14 (≈ height/2).
            bubble.backgroundColor = .systemGray6
            bubble.layer.cornerRadius = 14
            centerConstraint.isActive = true
            outerStack.alignment = .center
            bubbleRow.alignment = .center
        }
    }

    /// Plain URLSession load — no caching, no auto-retry. L3+ uses
    /// RetryableImageView; L2 keeps it tiny.
    private func loadAvatar(url: URL?) {
        avatarView.image = UIImage(systemName: "person.circle.fill")
        guard let url else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self?.avatarView.image = image
            }
        }
        avatarTask = task
        task.resume()
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
