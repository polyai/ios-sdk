// Copyright PolyAI Limited

//  ChatViewController.swift
//  Examples/UIKit/01-Hello
//
//  Mirrors README:
//    - § "Get started > Use in your app > UIKit"
//

import UIKit
import Combine
import PolyMessaging

final class ChatViewController: UIViewController {

    // F2/F3: hard-stop length cap (matches web MAX_MESSAGE_LENGTH=500).
    static let maxMessageLength = 500

    // Wired in Main.storyboard.
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var inputField: UITextField!
    @IBOutlet weak var sendButton: UIButton!

    // Store one ChatSession per chat surface — don't recreate on appearance.
    private var session: ChatSession!
    private var bag = Set<AnyCancellable>()

    // Diffable data source keyed by ChatMessage.id (UUID).
    private var dataSource: UITableViewDiffableDataSource<Int, UUID>!

    // F1: WhatsApp-style follow. `autoFollow` is sticky — new content scrolls to
    // the bottom while it's true, and shows the "New messages" pill instead while
    // it's false. ONLY the user's own scrolling flips it (see the table delegate):
    // drag up away from the bottom turns following off; scroll back (or tap the
    // pill, or send) turns it on. Decoupling from instantaneous geometry is what
    // keeps a streaming reply or an in-flight scroll animation from being misread
    // as "the user scrolled up".
    private let newMessagesPill = UIButton(type: .system)
    private var hasNewBelow = false {
        didSet { setPillVisible(hasNewBelow) }
    }
    private var autoFollow = true
    // True only between a user touch starting and the scroll settling, so
    // programmatic follow-scrolls don't get mistaken for the user scrolling away.
    private var isUserScrolling = false
    // True while the local user just sent — forces a follow-scroll even if they
    // had scrolled up a bit.
    private var pendingUserSendScroll = false

    override func viewDidLoad() {
        super.viewDidLoad()
        session = PolyMessaging.chat()
        applyKeyboardAvoidance()
        configureDataSource()
        configureNewMessagesPill()
        bind()

        // The storyboard already styles the composer (rounded text field + "Send"
        // button). All we add in code is the accessibility identifiers the UITests
        // query, and disabling Send while the field is empty.
        inputField.accessibilityIdentifier = "composer"
        sendButton.accessibilityIdentifier = "sendButton"
        inputField.delegate = self
        inputField.addAction(UIAction { [weak self] _ in
            self?.enforceMaxLength()
            self?.updateSendEnabled()
        }, for: .editingChanged)
    }

    // MARK: - New-messages pill (F1)

    private func configureNewMessagesPill() {
        newMessagesPill.translatesAutoresizingMaskIntoConstraints = false
        var conf = UIButton.Configuration.filled()
        conf.image = UIImage(systemName: "arrow.down")
        conf.imagePadding = 6
        conf.cornerStyle = .capsule
        conf.baseBackgroundColor = .systemBlue
        conf.baseForegroundColor = .white
        conf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        var titleAttr = AttributeContainer()
        titleAttr.font = .systemFont(ofSize: 13, weight: .semibold)
        conf.attributedTitle = AttributedString("New messages", attributes: titleAttr)
        newMessagesPill.configuration = conf
        newMessagesPill.accessibilityLabel = "Scroll to newest messages"
        newMessagesPill.layer.shadowColor = UIColor.black.cgColor
        newMessagesPill.layer.shadowOpacity = 0.2
        newMessagesPill.layer.shadowRadius = 4
        newMessagesPill.layer.shadowOffset = CGSize(width: 0, height: 2)
        newMessagesPill.alpha = 0
        newMessagesPill.isHidden = true
        newMessagesPill.addTarget(self, action: #selector(newMessagesPillTapped), for: .touchUpInside)
        view.addSubview(newMessagesPill)
        NSLayoutConstraint.activate([
            newMessagesPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Float just above the composer.
            newMessagesPill.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -10),
        ])
    }

    @objc private func newMessagesPillTapped() {
        autoFollow = true
        hasNewBelow = false
        scrollToBottom(animated: true)
    }

    private func setPillVisible(_ visible: Bool) {
        if visible { newMessagesPill.isHidden = false }
        UIView.animate(withDuration: 0.2, animations: {
            self.newMessagesPill.alpha = visible ? 1 : 0
        }, completion: { _ in
            if !visible { self.newMessagesPill.isHidden = true }
        })
    }

    /// F1: the user is "near the bottom" if the last bit of content is within a
    /// small threshold of the visible bottom edge. Computed from the scroll
    /// geometry BEFORE applying a snapshot so we can decide whether to follow.
    private func isNearBottom() -> Bool {
        let threshold: CGFloat = 80
        let visibleBottom = tableView.contentOffset.y + tableView.bounds.height
            - tableView.adjustedContentInset.bottom
        let contentBottom = tableView.contentSize.height
        // Treat an empty/short list (content fits the viewport) as "at bottom".
        if contentBottom <= tableView.bounds.height - tableView.adjustedContentInset.top {
            return true
        }
        return contentBottom - visibleBottom <= threshold
    }

    // F2/F3: hard-stop 500-char cap (matches web MAX_MESSAGE_LENGTH).
    private func enforceMaxLength() {
        let text = inputField.text ?? ""
        guard text.count > Self.maxMessageLength else { return }
        inputField.text = String(text.prefix(Self.maxMessageLength))
    }

    /// Keep the input bar above the keyboard. The storyboard pins the field to
    /// the safe-area bottom; swap that for the keyboard layout guide so typing
    /// doesn't hide the field + send button (matches the other UIKit examples).
    private func applyKeyboardAvoidance() {
        for c in view.constraints where
            (c.firstItem === inputField && c.firstAttribute == .bottom) ||
            (c.secondItem === inputField && c.secondAttribute == .bottom) {
            c.isActive = false
        }
        inputField.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8
        ).isActive = true
        tableView.keyboardDismissMode = .interactive
    }

    private func updateSendEnabled() {
        // Sending stays available offline — the SDK sends optimistically and
        // tracks delivery. Gate on hasEnded only, not on connection readiness.
        // F6: trim whitespace AND newlines so a whitespace-only draft can't enable Send.
        let hasText = !(inputField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        sendButton.isEnabled = hasText && !session.hasEnded
    }

    private func configureDataSource() {
        tableView.register(MessageCell.self, forCellReuseIdentifier: "cell")
        tableView.delegate = self
        dataSource = UITableViewDiffableDataSource<Int, UUID>(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MessageCell
            let message = self?.session.messages.first(where: { $0.id == id })
            cell.configure(text: message?.text ?? "", isUser: message?.isUser ?? false)
            return cell
        }
    }

    private func bind() {
        session.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                self?.render(messages)
            }
            .store(in: &bag)

        session.$hasEnded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateSendEnabled()
            }
            .store(in: &bag)

        // `failureReason` is non-nil once the SDK hits a terminal failure it
        // can't auto-recover from — most notably an invalid `apiKey`.
        // Show a "Couldn't connect" alert with a Try Again button instead of
        // letting the app sit silently with an empty table view.
        session.$failureReason
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] reason in
                self?.presentFailureAlert(reason: reason)
            }
            .store(in: &bag)
    }

    private var isPresentingFailureAlert = false

    private func presentFailureAlert(reason: PolyError) {
        guard !isPresentingFailureAlert, presentedViewController == nil else { return }
        isPresentingFailureAlert = true
        // a useful "auth(unauthorized)" instead of Error's generic default.
        let alert = UIAlertController(
            title: "Couldn't connect",
            message: String(describing: reason),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.isPresentingFailureAlert = false
            Task { try? await self?.session.client.resume() }
        })
        present(alert, animated: true)
    }

    private func render(_ messages: [ChatMessage]) {
        // F1: follow the new content if we're sticking to the bottom (autoFollow),
        // or if the user just sent a message themselves. Otherwise the snapshot
        // lands silently and the "New messages" pill appears.
        let near = autoFollow || pendingUserSendScroll
        let forceScroll = pendingUserSendScroll
        pendingUserSendScroll = false

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        let ids = messages.map(\.id)
        snapshot.appendItems(ids)
        let existing = dataSource.snapshot().itemIdentifiers
        let toReconfigure = ids.filter { existing.contains($0) }
        if !toReconfigure.isEmpty {
            snapshot.reconfigureItems(toReconfigure)
        }
        // The completion handler fires after every apply — including the
        // reconfigureItems case the streaming text-growth path hits.
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
            self?.followOrNotify(wasNearBottom: near, animated: true, force: forceScroll)
        }
    }

    /// F1: after content changes, either follow to the bottom (user was already
    /// there, or just sent) or surface the "New messages" pill.
    private func followOrNotify(wasNearBottom: Bool, animated: Bool, force: Bool = false) {
        if wasNearBottom || force {
            autoFollow = true
            hasNewBelow = false
            scrollToBottom(animated: animated)
        } else {
            hasNewBelow = true
        }
    }

    private func scrollToBottom(animated: Bool) {
        // layoutIfNeeded lets the just-reconfigured cell expand to its new
        // height before we ask for the bottom row's position.
        tableView.layoutIfNeeded()
        let count = tableView.numberOfRows(inSection: 0)
        guard count > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: count - 1, section: 0),
                              at: .bottom, animated: animated)
    }

    @IBAction func sendTapped(_ sender: Any) {
        sendCurrentText()
    }

    private func sendCurrentText() {
        // F6: trim whitespace AND newlines for the send guard.
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.text = ""
        updateSendEnabled()
        // F1: the local user just sent — always follow to the bottom on next render.
        autoFollow = true
        pendingUserSendScroll = true
        Task { try? await self.session.send(text) }
    }
}

// MARK: - UITextFieldDelegate

extension ChatViewController: UITextFieldDelegate {
    // F2/F3: enforce the 500-char cap proactively so paste can't exceed it.
    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        guard let r = Range(range, in: current) else { return true }
        let updated = current.replacingCharacters(in: r, with: string)
        if updated.count > Self.maxMessageLength {
            // Allow a truncated paste rather than rejecting the whole thing.
            let allowed = Self.maxMessageLength - (current.count - range.length)
            guard allowed > 0 else { return false }
            let insert = String(string.prefix(allowed))
            textField.text = current.replacingCharacters(in: r, with: insert)
            updateSendEnabled()
            return false
        }
        return true
    }

    // Return sends.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendCurrentText()
        return false
    }
}

// MARK: - MessageCell

/// A chat row whose bubble (the padded, rounded, colored container holding the
/// message label) aligns leading for the agent and trailing for the user.
///
/// F5 follow-up: cap the bubble at ~75% of the cell's content width so messages
/// never stretch edge-to-edge on iPad / landscape. The opposite-side gap is what
/// makes the leading/trailing alignment read clearly.
final class MessageCell: UITableViewCell {

    private let bubble = UIView()
    private let label = UILabel()

    // Toggle leading vs. trailing pin per message so the bubble hugs the correct
    // side. Both stay <= 75% of the content width.
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        selectionStyle = .none
        backgroundColor = .clear

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 16
        contentView.addSubview(bubble)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        bubble.addSubview(label)

        leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            // Never wider than ~75% of the cell's content width — leaves a gap on
            // the opposite side for both leading (agent) and trailing (user) bubbles.
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.75),

            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
        ])
    }

    func configure(text: String, isUser: Bool) {
        label.text = text
        if isUser {
            label.textColor = .white
            bubble.backgroundColor = .systemBlue
            leadingConstraint.isActive = false
            trailingConstraint.isActive = true
        } else {
            label.textColor = .label
            bubble.backgroundColor = .secondarySystemBackground
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
        }
    }
}

// MARK: - UITableViewDelegate (F1: user-driven autoFollow)

extension ChatViewController: UITableViewDelegate {
    // Only a user drag changes the follow intent. Programmatic follow-scrolls
    // never call scrollViewWillBeginDragging, so they leave autoFollow untouched.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isUserScrolling = true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isUserScrolling else { return }
        updateAutoFollow()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { isUserScrolling = false }
        updateAutoFollow()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isUserScrolling = false
        updateAutoFollow()
    }

    /// Stick to the bottom (and clear the pill) when the user is parked near it;
    /// stop following the moment they pull up into history.
    private func updateAutoFollow() {
        autoFollow = isNearBottom()
        if autoFollow, hasNewBelow { hasNewBelow = false }
    }
}
