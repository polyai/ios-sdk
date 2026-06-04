// Copyright PolyAI Limited

//  ChatViewController.swift
//  Examples/UIKit/03-RichContent
//
//  Mirrors README:
//    - § "Get started > Use in your app > UIKit"
//    - § "Best practices > Trust the typing throttle"
//    - § "Best practices > Render reconnects as a banner"
//    - § "Best practices > Surface .failed with a manual retry"
//    - § "Best practices > Handle keyboard yourself"
//

import UIKit
import Combine
import PolyMessaging

final class ChatViewController: UIViewController {

    // F2/F3: hard-stop 500-char cap (matches web MAX_MESSAGE_LENGTH).
    static let maxMessageLength = 500

    // Only the End button is wired in the Storyboard — everything else is
    // built programmatically to keep the Storyboard XML small and robust.
    @IBOutlet weak var endButton: UIBarButtonItem?
    private var endButtonRef: UIBarButtonItem?

    // Store one ChatSession per chat surface — don't recreate on appearance.
    private var session: ChatSession!
    private var bag = Set<AnyCancellable>()

    // New-message banners (foreground + grace window) — see NewMessageNotifier.swift
    // (see Components/NewMessageNotifier.swift).
    private let messageNotifier = NewMessageNotifier()

    // Rows: each message, plus a suggestions pill-row appended under the last
    // agent message (mirrors 06 — pills live in the list, not pinned above input).
    private enum Row: Hashable {
        case message(UUID)
        case suggestions(UUID)
    }
    private var dataSource: UITableViewDiffableDataSource<Int, Row>!

    // Programmatic views.
    private let bannerStack = UIStackView()
    private let connectionBanner = UIView()
    private let connectionSpinner = UIActivityIndicatorView(style: .medium)
    private let connectionLabel = UILabel()
    private let tableView = UITableView()
    private let typingFooter = UIView()
    private let typingIndicator = TypingDotsView()
    private let inputBar = UIView()
    private let inputBarBorder = UIView()
    private let inputFieldBackground = UIView()
    // F4: a growing multi-line composer (1–5 lines, then scrolls) replaces the
    // old single-line UITextField. Return still sends; newlines arrive via paste.
    private let inputField = UITextView()
    private let inputPlaceholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let failureOverlay = UIView()
    private let failureLabel = UILabel()
    private let reconnectButton = UIButton(type: .system)
    private let chatEndedView = UIView()
    private let startNewChatButton = UIButton(type: .system)

    // F4: composer height that grows with content, capped at ~5 lines.
    private var inputFieldHeight: NSLayoutConstraint!
    private static let composerMinHeight: CGFloat = 36
    private static let composerMaxHeight: CGFloat = 120

    // F1: "New messages" pill — shown when new content arrives while the user is
    // scrolled up, instead of yanking the table to the bottom.
    private let newMessagesPill = UIButton(type: .system)
    private var newMessagesPillBottom: NSLayoutConstraint!
    private var hasNewBelow = false {
        didSet { setPillVisible(hasNewBelow) }
    }
    // True while the local user just sent — forces a follow-scroll even if they
    // had scrolled up a bit.
    private var pendingUserSendScroll = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Chat"
        session = PolyMessaging.chat()
        // Cache the End button so we can show/hide it on session end (iOS 15
        // doesn't have UIBarButtonItem.isHidden — remove/restore instead).
        endButtonRef = navigationItem.rightBarButtonItem
        layoutUI()
        configureDataSource()
        bind()
        updateSendEnabled()
        messageNotifier.start(observing: session)
    }

    // MARK: - Layout

    private func layoutUI() {
        layoutConnectionBanner()
        layoutTable()
        configureTypingFooter()
        layoutInputBar()
        configureNewMessagesPill()
        layoutChatEndedView()
        layoutFailureOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTypingFooterFrame()
    }

    private func layoutConnectionBanner() {
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        connectionBanner.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.15)
        connectionBanner.isHidden = true

        // The banner sits in a stack pinned to the safe-area top. A stack
        // collapses hidden arranged subviews, so the table reaches the top with
        // no reserved padding when not reconnecting (safe area is kept).
        bannerStack.axis = .vertical
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        bannerStack.addArrangedSubview(connectionBanner)
        view.addSubview(bannerStack)

        connectionSpinner.translatesAutoresizingMaskIntoConstraints = false
        connectionSpinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        connectionSpinner.hidesWhenStopped = false
        connectionBanner.addSubview(connectionSpinner)

        connectionLabel.translatesAutoresizingMaskIntoConstraints = false
        connectionLabel.font = .systemFont(ofSize: 13)
        connectionLabel.textColor = .secondaryLabel
        connectionLabel.text = "Reconnecting..."
        connectionBanner.addSubview(connectionLabel)

        NSLayoutConstraint.activate([
            bannerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bannerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bannerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            connectionSpinner.centerYAnchor.constraint(equalTo: connectionBanner.centerYAnchor),
            connectionSpinner.trailingAnchor.constraint(equalTo: connectionLabel.leadingAnchor, constant: -4),

            connectionLabel.centerXAnchor.constraint(equalTo: connectionBanner.centerXAnchor, constant: 6),
            connectionLabel.topAnchor.constraint(equalTo: connectionBanner.topAnchor, constant: 6),
            connectionLabel.bottomAnchor.constraint(equalTo: connectionBanner.bottomAnchor, constant: -6),
        ])
    }

    private func layoutTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .interactive
        // Cells host rich content (attachments, URL cards, call actions), so
        // sizing must self-compute via Auto Layout.
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
        tableView.register(SuggestionsCell.self, forCellReuseIdentifier: SuggestionsCell.reuseID)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: bannerStack.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func configureTypingFooter() {
        typingFooter.backgroundColor = .systemBackground
        typingIndicator.translatesAutoresizingMaskIntoConstraints = false
        typingFooter.addSubview(typingIndicator)

        NSLayoutConstraint.activate([
            typingIndicator.topAnchor.constraint(equalTo: typingFooter.topAnchor, constant: 4),
            typingIndicator.leadingAnchor.constraint(equalTo: typingFooter.leadingAnchor, constant: 12),
            typingIndicator.trailingAnchor.constraint(lessThanOrEqualTo: typingFooter.trailingAnchor, constant: -12),
            typingIndicator.bottomAnchor.constraint(lessThanOrEqualTo: typingFooter.bottomAnchor, constant: -8),
        ])
    }

    private func layoutInputBar() {
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.backgroundColor = .systemBackground
        view.addSubview(inputBar)

        inputBarBorder.translatesAutoresizingMaskIntoConstraints = false
        inputBarBorder.backgroundColor = .separator
        inputBar.addSubview(inputBarBorder)

        inputFieldBackground.translatesAutoresizingMaskIntoConstraints = false
        inputFieldBackground.backgroundColor = .systemGray6
        inputFieldBackground.layer.cornerRadius = 18
        inputFieldBackground.layer.masksToBounds = true
        inputBar.addSubview(inputFieldBackground)

        // F4: a growing multi-line UITextView replaces the single-line field.
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.accessibilityIdentifier = "composer"
        inputField.font = .systemFont(ofSize: 15)
        inputField.backgroundColor = .clear
        inputField.returnKeyType = .send
        inputField.isScrollEnabled = false          // grows with content until the height cap
        inputField.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        inputField.textContainer.lineFragmentPadding = 0
        inputField.delegate = self
        inputFieldBackground.addSubview(inputField)

        // Hand-rolled placeholder (UITextView has none) — hidden once text exists.
        inputPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        inputPlaceholder.text = "Message..."
        inputPlaceholder.font = .systemFont(ofSize: 15)
        inputPlaceholder.textColor = .placeholderText
        inputPlaceholder.isUserInteractionEnabled = false
        inputFieldBackground.addSubview(inputPlaceholder)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.accessibilityIdentifier = "sendButton"
        var sconf = UIButton.Configuration.plain()
        sconf.image = UIImage(systemName: "arrow.up.circle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 36))
        sconf.baseForegroundColor = .systemBlue
        sconf.contentInsets = .zero
        sendButton.configuration = sconf
        sendButton.configurationUpdateHandler = { btn in
            var c = btn.configuration
            c?.baseForegroundColor = btn.isEnabled ? .systemBlue : .systemGray3
            btn.configuration = c
        }
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        inputBar.addSubview(sendButton)

        // F4: the composer grows with content; this constraint is updated as the
        // text view's content height changes (clamped between min and max).
        inputFieldHeight = inputField.heightAnchor.constraint(equalToConstant: Self.composerMinHeight)

        // Pin the input bar to the keyboard layout guide so it rides the keyboard
        // up/down automatically — see "Best practices > Handle keyboard yourself".
        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            // Suggestions now render as a list row, so the table pins straight to
            // the composer.
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBarBorder.topAnchor.constraint(equalTo: inputBar.topAnchor),
            inputBarBorder.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            inputBarBorder.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),
            inputBarBorder.heightAnchor.constraint(equalToConstant: 0.5),

            // The field background hugs the (growing) text view; the input bar in
            // turn sizes to the background + vertical padding, so the whole bar
            // grows. Bottom anchors keep the send button aligned to the last line.
            inputFieldBackground.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: 12),
            inputFieldBackground.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: 8),
            inputFieldBackground.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -8),
            inputFieldBackground.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            inputField.leadingAnchor.constraint(equalTo: inputFieldBackground.leadingAnchor, constant: 14),
            inputField.trailingAnchor.constraint(equalTo: inputFieldBackground.trailingAnchor, constant: -14),
            inputField.topAnchor.constraint(equalTo: inputFieldBackground.topAnchor),
            inputField.bottomAnchor.constraint(equalTo: inputFieldBackground.bottomAnchor),
            inputFieldHeight,

            inputPlaceholder.leadingAnchor.constraint(equalTo: inputField.leadingAnchor),
            inputPlaceholder.topAnchor.constraint(equalTo: inputField.topAnchor, constant: 8),

            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -12),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    /// F4: clamp the composer height to its content between min and max; enable
    /// internal scrolling only once it hits the max (~5 lines).
    private func updateComposerHeight() {
        let fitting = inputField.sizeThatFits(
            CGSize(width: inputField.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        let clamped = min(max(fitting, Self.composerMinHeight), Self.composerMaxHeight)
        let shouldScroll = fitting > Self.composerMaxHeight
        if inputField.isScrollEnabled != shouldScroll { inputField.isScrollEnabled = shouldScroll }
        if abs(inputFieldHeight.constant - clamped) > 0.5 {
            inputFieldHeight.constant = clamped
            view.layoutIfNeeded()
        }
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
        ])
        // Pill bottom constraint floats it just above the input bar.
        newMessagesPillBottom = newMessagesPill.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -10)
        newMessagesPillBottom.isActive = true
    }

    @objc private func newMessagesPillTapped() {
        hasNewBelow = false
        scrollTableToBottom(animated: true)
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

    private func layoutChatEndedView() {
        chatEndedView.translatesAutoresizingMaskIntoConstraints = false
        chatEndedView.backgroundColor = .secondarySystemBackground
        chatEndedView.isHidden = true
        view.addSubview(chatEndedView)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "This conversation has ended. Please start a new chat to continue."
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        chatEndedView.addSubview(label)

        startNewChatButton.translatesAutoresizingMaskIntoConstraints = false
        var conf = UIButton.Configuration.borderedProminent()
        conf.title = "Start New Conversation"
        conf.buttonSize = .small
        startNewChatButton.configuration = conf
        startNewChatButton.addTarget(self, action: #selector(startNewChatTapped), for: .touchUpInside)
        chatEndedView.addSubview(startNewChatButton)

        // Same anchoring as inputBar so the swap is seamless.
        NSLayoutConstraint.activate([
            chatEndedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatEndedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatEndedView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            label.topAnchor.constraint(equalTo: chatEndedView.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: chatEndedView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: chatEndedView.trailingAnchor, constant: -20),

            startNewChatButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            startNewChatButton.centerXAnchor.constraint(equalTo: chatEndedView.centerXAnchor),
            startNewChatButton.bottomAnchor.constraint(equalTo: chatEndedView.bottomAnchor, constant: -12),
        ])
    }

    private func layoutFailureOverlay() {
        failureOverlay.translatesAutoresizingMaskIntoConstraints = false
        failureOverlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        failureOverlay.isHidden = true
        view.addSubview(failureOverlay)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        failureOverlay.addSubview(card)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Connection lost"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        card.addSubview(title)

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.font = .systemFont(ofSize: 13)
        failureLabel.textColor = .secondaryLabel
        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .center
        card.addSubview(failureLabel)

        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        var rc = UIButton.Configuration.borderedProminent()
        rc.title = "Reconnect"
        reconnectButton.configuration = rc
        reconnectButton.addTarget(self, action: #selector(reconnectTapped), for: .touchUpInside)
        card.addSubview(reconnectButton)

        NSLayoutConstraint.activate([
            failureOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            failureOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            failureOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card.centerXAnchor.constraint(equalTo: failureOverlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: failureOverlay.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: failureOverlay.leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(equalTo: failureOverlay.trailingAnchor, constant: -32),

            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            failureLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            failureLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            failureLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            reconnectButton.topAnchor.constraint(equalTo: failureLabel.bottomAnchor, constant: 16),
            reconnectButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            reconnectButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Data source

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) {
            [weak self] tableView, indexPath, row in
            guard let self else { return UITableViewCell() }
            switch row {
            case .message(let id):
                let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
                if let message = self.session.messages.first(where: { $0.id == id }) {
                    let pending: Bool
                    if case .user(let m) = message, m.delivery == .pending { pending = true } else { pending = false }
                    cell.configure(
                        with: message,
                        onRetry: { [weak self] text in
                            Task { try? await self?.session.send(text) }
                        },
                        showSendingLabel: pending
                    )
                }
                return cell
            case .suggestions(let id):
                let cell = tableView.dequeueReusableCell(withIdentifier: SuggestionsCell.reuseID, for: indexPath) as! SuggestionsCell
                if let message = self.session.messages.first(where: { $0.id == id }) {
                    cell.configure(suggestions: message.suggestions) { [weak self] suggestion in
                        self?.session.clearSuggestions(for: id)
                        Task { try? await self?.session.send(suggestion.messageText) }
                    }
                }
                return cell
            }
        }
        tableView.dataSource = dataSource
    }

    // MARK: - Bindings

    private func bind() {
        // Render messages.
        session.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                self?.render(messages)
            }
            .store(in: &bag)

        // Typing indicator — render as table footer so it sits directly
        // after the latest message, matching the SwiftUI LazyVStack layout.
        session.$isAgentTyping
            .receive(on: RunLoop.main)
            .sink { [weak self] typing in
                guard let self else { return }
                if typing {
                    let lastAgent = self.session.messages.reversed().first(where: {
                        if case .agent = $0 { return true } else { return false }
                    })
                    if case .agent(let am) = lastAgent {
                        self.typingIndicator.setAvatar(url: am.avatarUrl)
                    } else {
                        self.typingIndicator.setAvatar(url: nil)
                    }
                }
                self.setTypingIndicatorVisible(typing)
            }
            .store(in: &bag)

        // Connection banner — mirrors README "Best practices > Render reconnects as a banner".
        session.$connection
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if case .reconnecting = status {
                    self.connectionBanner.isHidden = false
                    self.connectionSpinner.startAnimating()
                } else {
                    self.connectionBanner.isHidden = true
                    self.connectionSpinner.stopAnimating()
                }
            }
            .store(in: &bag)

        // Failure overlay — mirrors README "Best practices > Surface .failed with a manual retry".
        session.$failureReason
            .receive(on: RunLoop.main)
            .sink { [weak self] reason in
                self?.failureOverlay.isHidden = (reason == nil)
                // falls back to Error's generic default. Use String(describing:).
                self?.failureLabel.text = reason.map { String(describing: $0) }
            }
            .store(in: &bag)

        // Send button enablement + End button visibility + input/ended swap.
        // Composing stays available while offline/reconnecting — the SDK sends
        // optimistically and tracks delivery (pending → failed → retry). Gate the
        // composer on hasEnded only, never on connection readiness.
        session.$hasEnded
            .receive(on: RunLoop.main)
            .sink { [weak self] ended in
                guard let self else { return }
                self.inputField.isEditable = !ended
                self.updateSendEnabled()
                // Hide the End button after the conversation ends.
                self.navigationItem.rightBarButtonItem = ended ? nil : self.endButtonRef
                // Swap the input bar with the chat-ended footer.
                self.inputBar.isHidden = ended
                self.chatEndedView.isHidden = !ended
                // Re-render so the suggestions row drops when the chat ends.
                if ended { self.render(self.session.messages) }
            }
            .store(in: &bag)
    }

    private func setTypingIndicatorVisible(_ visible: Bool) {
        if visible {
            // F1: capture position before adding the footer changes contentSize.
            let near = isNearBottom()
            updateTypingFooterFrame()
            tableView.tableFooterView = typingFooter
            typingIndicator.start()
            followOrNotify(wasNearBottom: near, animated: true)
        } else {
            typingIndicator.stop()
            tableView.tableFooterView = UIView(frame: .zero)
        }
    }

    private func updateTypingFooterFrame() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let targetFrame = CGRect(x: 0, y: 0, width: width, height: 44)
        if typingFooter.frame != targetFrame {
            typingFooter.frame = targetFrame
            if tableView.tableFooterView === typingFooter {
                tableView.tableFooterView = typingFooter
            }
        }
    }

    private func render(_ messages: [ChatMessage]) {
        // F1: decide whether to follow the new content BEFORE applying the
        // snapshot, from the current scroll geometry. Follow only if the user is
        // already near the bottom, or if they just sent a message themselves.
        let near = isNearBottom() || pendingUserSendScroll
        let forceScroll = pendingUserSendScroll
        pendingUserSendScroll = false

        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        var rows = messages.map { Row.message($0.id) }
        // Suggestions render as their own row under the last agent message, so
        // showing/hiding them never resizes a bubble cell (mirrors 06).
        if let suggestionId = suggestionMessageId(in: messages) {
            rows.append(.suggestions(suggestionId))
        }
        snapshot.appendItems(rows)
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let toReconfigure = rows.filter { existing.contains($0) }
        if !toReconfigure.isEmpty {
            snapshot.reconfigureItems(toReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
            self?.followOrNotify(wasNearBottom: near, animated: true, force: forceScroll)
        }
    }

    /// F1: after content changes, either follow to the bottom (user was already
    /// there, or just sent) or surface the "New messages" pill.
    private func followOrNotify(wasNearBottom: Bool, animated: Bool, force: Bool = false) {
        if wasNearBottom || force {
            hasNewBelow = false
            scrollTableToBottom(animated: animated)
        } else {
            hasNewBelow = true
        }
    }

    /// The last message's id when it carries suggestions and the chat is live —
    /// drives the suggestions row. As soon as the user sends, their message becomes
    /// last (no suggestions) so the row drops until the agent replies. Mirrors 06.
    private func suggestionMessageId(in messages: [ChatMessage]) -> UUID? {
        guard !session.hasEnded, let last = messages.last, !last.suggestions.isEmpty else { return nil }
        return last.id
    }

    private func scrollTableToBottom(animated: Bool) {
        tableView.layoutIfNeeded()
        let minOffsetY = -tableView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        )
        tableView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: animated)
    }

    // MARK: - Actions

    @objc private func sendTapped() { sendCurrentText() }

    private func sendCurrentText() {
        // F6: trim whitespace AND newlines for the send guard.
        let text = inputField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.text = ""
        updateComposerHeight()
        updateSendEnabled()
        // F1: the local user just sent — always follow to the bottom on the next render.
        pendingUserSendScroll = true
        Task { try? await self.session.send(text) }
    }

    private func updateSendEnabled() {
        let enabled = !session.hasEnded
        // F6: trim newlines too, so a composer holding only whitespace/newlines
        // can't enable Send.
        let hasText = !inputField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = enabled && hasText
        inputPlaceholder.isHidden = !inputField.text.isEmpty
    }

    // F2/F3: hard-stop 500-char cap (matches web MAX_MESSAGE_LENGTH).
    private func enforceMaxLength() {
        let text = inputField.text ?? ""
        guard text.count > Self.maxMessageLength else { return }
        inputField.text = String(text.prefix(Self.maxMessageLength))
    }

    @IBAction func endTapped(_ sender: Any) {
        Task { try? await self.session.end() }
    }

    @objc private func reconnectTapped() {
        Task { try? await self.session.client.resume() }
    }

    @objc private func startNewChatTapped() {
        Task { try? await self.session.client.startNewSession() }
    }
}

// MARK: - UITextViewDelegate

extension ChatViewController: UITextViewDelegate {
    // F4: Return sends. Intercept the newline replacement and trigger a send
    // instead of inserting it; multi-line input still arrives via paste.
    func textView(_ textView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        if text == "\n" {
            sendCurrentText()
            return false
        }
        // F2/F3: enforce the 500-char cap proactively so paste can't exceed it.
        let current = textView.text ?? ""
        guard let r = Range(range, in: current) else { return true }
        let updated = current.replacingCharacters(in: r, with: text)
        if updated.count > Self.maxMessageLength {
            // Allow a truncated paste rather than rejecting the whole thing.
            let allowed = Self.maxMessageLength - (current.count - range.length)
            guard allowed > 0 else { return false }
            let insert = String(text.prefix(allowed))
            textView.text = current.replacingCharacters(in: r, with: insert)
            textViewDidChange(textView)
            return false
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        enforceMaxLength()
        updateComposerHeight()
        updateSendEnabled()
        // SDK throttles STARTED frames to ≤1/3s — safe to call on every keystroke.
        // Mirrors README "Best practices > Trust the typing throttle".
        if !textView.text.isEmpty {
            Task { await session.sendTyping() }
        }
    }
}

// MARK: - SuggestionsCell

/// Full-width row that hosts the horizontal `SuggestionsView` pill scroller for
/// the last agent message. Rendered as its own table row so showing/hiding
/// suggestions never resizes a message bubble cell.
private final class SuggestionsCell: UITableViewCell {
    static let reuseID = "SuggestionsCell"
    private let suggestions = SuggestionsView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(suggestions)
        NSLayoutConstraint.activate([
            suggestions.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            suggestions.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            suggestions.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            suggestions.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            suggestions.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(suggestions list: [ResponseSuggestion], onTap: @escaping (ResponseSuggestion) -> Void) {
        suggestions.update(suggestions: list, onTap: onTap)
    }
}

// MARK: - TypingDotsView

/// Three animated dots in a gray bubble + agent avatar to the left.
/// Mirrors the SwiftUI `TypingIndicator` reference component.
private final class TypingDotsView: UIView {
    private let avatar = RetryableImageView()
    private let bubble = UIView()
    private let dots: [UIView] = (0..<3).map { _ in UIView() }
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 14
        avatar.layer.masksToBounds = true
        addSubview(avatar)

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = .systemGray5
        bubble.layer.cornerRadius = 18
        addSubview(bubble)

        let dotStack = UIStackView()
        dotStack.translatesAutoresizingMaskIntoConstraints = false
        dotStack.axis = .horizontal
        dotStack.spacing = 5
        dotStack.alignment = .center
        bubble.addSubview(dotStack)

        for dot in dots {
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = .systemGray2
            dot.layer.cornerRadius = 4
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            dotStack.addArrangedSubview(dot)
        }

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
            avatar.topAnchor.constraint(equalTo: topAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),

            bubble.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            dotStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            dotStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            dotStack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
            dotStack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard !isAnimating else { return }
        isAnimating = true
        for (i, dot) in dots.enumerated() {
            UIView.animate(withDuration: 0.5,
                           delay: Double(i) * 0.2,
                           options: [.repeat, .autoreverse, .curveEaseInOut],
                           animations: {
                dot.transform = CGAffineTransform(translationX: 0, y: -6)
            })
        }
    }

    func stop() {
        isAnimating = false
        dots.forEach {
            $0.layer.removeAllAnimations()
            $0.transform = .identity
        }
    }

    func setAvatar(url: URL?) {
        avatar.load(url: url)
    }
}
