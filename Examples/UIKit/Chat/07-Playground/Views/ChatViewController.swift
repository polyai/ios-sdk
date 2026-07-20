// Copyright PolyAI Limited

//  ChatViewController.swift
//  Examples/UIKit/07-Playground
//
//  The 06 chat surface plus the playground extras from the SwiftUI 07 ChatView:
//  an optional always-on debug strip at the top and optional iMessage-style
//  timestamp separators interleaved into the message list. The diffable data
//  source switches from plain message ids to a `Row` enum so separators can be
//  inserted between message groups.
//

import UIKit
import Combine
import PolyMessaging

final class ChatViewController: UIViewController {

    static let maxMessageLength = 500

    private let session: ChatSession
    private let wasResumed: Bool
    private let showDebugStrip: Bool
    private let showTimestamps: Bool
    private let diagnostics: DevDiagnostics
    private var bag = Set<AnyCancellable>()

    // New-message banners (foreground + grace window) — see NewMessageNotifier.swift
    // (see Components/NewMessageNotifier.swift).
    private let messageNotifier = NewMessageNotifier()

    private let network = NetworkMonitor()

    // The suggestions row is its own list item (not embedded in a bubble cell),
    // so showing/hiding it never resizes a message cell — in-cell suggestions
    // left reconfigured bubbles stuck at a stale, taller height.
    private enum Row: Hashable {
        case timestamp(UUID)
        case message(UUID)
        case suggestions(UUID)
    }
    private var dataSource: UITableViewDiffableDataSource<Int, Row>!

    private var sendingLabels: Set<UUID> = []
    private var trackedPending: Set<UUID> = []
    private var hasFailed = false
    private var resumeBannerShown = false

    private var debugStrip: DebugStripView?
    private let resumeBanner = UIView()
    private let offlineBanner = OfflineBanner()
    private let connectionBanner = UIView()
    private let connectionSpinner = UIActivityIndicatorView(style: .medium)
    private let connectionLabel = UILabel()
    private let tableView = UITableView()
    private let skeleton = LoadingSkeleton()
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
    private let chatEndedView = UIView()

    // Composer height that grows with content, capped at ~5 lines.
    private var inputFieldHeight: NSLayoutConstraint!
    private static let composerMinHeight: CGFloat = 36
    private static let composerMaxHeight: CGFloat = 120

    // F1: WhatsApp-style follow. `autoFollow` is sticky — new content scrolls to
    // the bottom while it's true, and shows the "New messages" pill instead while
    // it's false. ONLY the user's own scrolling flips it (see the table delegate):
    // drag up away from the bottom turns following off; scroll back (or tap the
    // pill, or send) turns it on. Decoupling from instantaneous geometry is what
    // keeps a streaming reply or an in-flight scroll animation from being misread
    // as "the user scrolled up".
    private let newMessagesPill = UIButton(type: .system)
    private var newMessagesPillBottom: NSLayoutConstraint!
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

    init(session: ChatSession, wasResumed: Bool, showDebugStrip: Bool, showTimestamps: Bool, diagnostics: DevDiagnostics) {
        self.session = session
        self.wasResumed = wasResumed
        self.showDebugStrip = showDebugStrip
        self.showTimestamps = showTimestamps
        self.diagnostics = diagnostics
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        layoutUI()
        configureDataSource()
        bind()
        messageNotifier.start(observing: session, policy: .whenBackgrounded)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showResumeBannerIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTypingFooterFrame()
    }

    // MARK: - Layout

    private func layoutUI() {
        let safe = view.safeAreaLayoutGuide
        var topAnchor = safe.topAnchor

        if showDebugStrip {
            let strip = DebugStripView(diagnostics: diagnostics)
            debugStrip = strip
            view.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.topAnchor.constraint(equalTo: safe.topAnchor),
                strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            topAnchor = strip.bottomAnchor
        }

        // Banners live in a vertical stack pinned to the top (below the debug
        // strip when present). A stack collapses hidden arranged subviews, so
        // when no banner is showing the table reaches the top with no reserved
        // padding (safe area is kept).
        let bannerStack = UIStackView(arrangedSubviews: [resumeBanner, offlineBanner, connectionBanner])
        bannerStack.axis = .vertical
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bannerStack)
        view.addSubview(tableView)
        view.addSubview(skeleton)
        view.addSubview(newMessagesPill)
        view.addSubview(inputBar)
        view.addSubview(chatEndedView)

        configureResumeBanner()
        configureConnectionBanner()
        configureTableView()
        configureTypingFooter()
        configureNewMessagesPill()
        configureInputBar()
        configureChatEndedView()

        resumeBanner.isHidden = true
        NSLayoutConstraint.activate([
            bannerStack.topAnchor.constraint(equalTo: topAnchor),
            bannerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bannerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // resumeBanner has no intrinsic height (its content is center-pinned).
            resumeBanner.heightAnchor.constraint(equalToConstant: 38),

            // Table fills everything between the banner stack and the input bar.
            tableView.topAnchor.constraint(equalTo: bannerStack.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            skeleton.topAnchor.constraint(equalTo: tableView.topAnchor),
            skeleton.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),

            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            // F1: the pill floats just above the input bar, horizontally centered.
            newMessagesPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            chatEndedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatEndedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatEndedView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        // Pill bottom constraint is toggled to slide it in/out above the input bar.
        newMessagesPillBottom = newMessagesPill.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -10)
        newMessagesPillBottom.isActive = true
    }

    private func configureResumeBanner() {
        resumeBanner.translatesAutoresizingMaskIntoConstraints = false
        resumeBanner.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        resumeBanner.clipsToBounds = true

        let icon = UIImageView(image: UIImage(systemName: "arrow.uturn.backward.circle.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        resumeBanner.addSubview(icon)

        let label = UILabel()
        label.text = "Resumed previous conversation"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        resumeBanner.addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: resumeBanner.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: resumeBanner.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: resumeBanner.centerYAnchor),
        ])
    }

    private func configureConnectionBanner() {
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        connectionBanner.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.15)
        connectionBanner.isHidden = true

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
            connectionSpinner.centerYAnchor.constraint(equalTo: connectionBanner.centerYAnchor),
            connectionSpinner.trailingAnchor.constraint(equalTo: connectionLabel.leadingAnchor, constant: -4),
            connectionLabel.centerXAnchor.constraint(equalTo: connectionBanner.centerXAnchor, constant: 6),
            connectionLabel.topAnchor.constraint(equalTo: connectionBanner.topAnchor, constant: 6),
            connectionLabel.bottomAnchor.constraint(equalTo: connectionBanner.bottomAnchor, constant: -6),
        ])
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseID)
        tableView.register(TimestampCell.self, forCellReuseIdentifier: TimestampCell.reuseID)
        tableView.register(SuggestionsCell.self, forCellReuseIdentifier: SuggestionsCell.reuseID)
        tableView.delegate = self   // F1: track the user's scrolling for autoFollow
        skeleton.isHidden = true
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

    private func configureNewMessagesPill() {
        newMessagesPill.translatesAutoresizingMaskIntoConstraints = false
        var conf = UIButton.Configuration.filled()
        conf.title = "New messages"
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
    }

    @objc private func newMessagesPillTapped() {
        autoFollow = true
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

    private func configureInputBar() {
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.backgroundColor = .systemBackground

        inputBarBorder.translatesAutoresizingMaskIntoConstraints = false
        inputBarBorder.backgroundColor = .separator
        inputBar.addSubview(inputBarBorder)

        inputFieldBackground.translatesAutoresizingMaskIntoConstraints = false
        inputFieldBackground.backgroundColor = .systemGray6
        inputFieldBackground.layer.cornerRadius = 18
        inputFieldBackground.layer.masksToBounds = true
        inputBar.addSubview(inputFieldBackground)

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

        NSLayoutConstraint.activate([
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

    private func configureChatEndedView() {
        chatEndedView.translatesAutoresizingMaskIntoConstraints = false
        chatEndedView.backgroundColor = .secondarySystemBackground
        chatEndedView.isHidden = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "This conversation has ended. Please start a new chat to continue."
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        chatEndedView.addSubview(label)

        var conf = UIButton.Configuration.borderedProminent()
        conf.title = "Start New Conversation"
        conf.buttonSize = .small
        let button = UIButton(configuration: conf, primaryAction: UIAction { [weak self] _ in
            self?.startNewConversationInPlace()
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        chatEndedView.addSubview(button)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: chatEndedView.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: chatEndedView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: chatEndedView.trailingAnchor, constant: -20),

            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            button.centerXAnchor.constraint(equalTo: chatEndedView.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: chatEndedView.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Data source

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) {
            [weak self] tableView, indexPath, row in
            guard let self else { return UITableViewCell() }
            switch row {
            case .timestamp(let mid):
                let cell = tableView.dequeueReusableCell(withIdentifier: TimestampCell.reuseID, for: indexPath) as! TimestampCell
                if let msg = self.session.messages.first(where: { $0.id == mid }) {
                    cell.configure(text: MessageTimestamp.groupHeader(msg.timestamp))
                }
                return cell
            case .message(let mid):
                let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
                if let message = self.session.messages.first(where: { $0.id == mid }) {
                    cell.configure(with: message, showSendingLabel: self.sendingLabels.contains(mid))
                    cell.onRetry = { [weak self] text in
                        if let draftId = self?.draftId(for: mid) { self?.session.removeMessage(draftId: draftId) }
                        Task { try? await self?.session.send(text) }
                    }
                }
                return cell
            case .suggestions(let mid):
                let cell = tableView.dequeueReusableCell(withIdentifier: SuggestionsCell.reuseID, for: indexPath) as! SuggestionsCell
                if let message = self.session.messages.first(where: { $0.id == mid }) {
                    cell.configure(suggestions: message.suggestions) { [weak self] suggestion in
                        self?.session.clearSuggestions(for: mid)
                        Task { try? await self?.session.send(suggestion.messageText) }
                    }
                }
                return cell
            }
        }
        tableView.dataSource = dataSource
    }

    private func draftId(for id: UUID) -> String? {
        guard case .user(let u) = session.messages.first(where: { $0.id == id }) else { return nil }
        return u.draftId
    }

    private func rows(for messages: [ChatMessage]) -> [Row] {
        var result: [Row] = []
        var previous: Date?
        for msg in messages {
            if showTimestamps, MessageTimestamp.shouldInsertSeparator(previous: previous, current: msg.timestamp) {
                result.append(.timestamp(msg.id))
            }
            result.append(.message(msg.id))
            previous = msg.timestamp
        }
        return result
    }

    // MARK: - Bindings

    private func bind() {
        session.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                guard let self else { return }
                self.syncSendingLabels(messages)
                self.render(messages)
                self.updateSkeletonVisibility()
            }
            .store(in: &bag)

        session.$isAgentTyping
            .receive(on: RunLoop.main)
            .sink { [weak self] typing in
                guard let self else { return }
                if typing {
                    let lastAgent = self.session.messages.reversed().first {
                        if case .agent = $0 { return true } else { return false }
                    }
                    if case .agent(let am) = lastAgent {
                        self.typingIndicator.setAvatar(url: am.avatarUrl)
                    } else {
                        self.typingIndicator.setAvatar(url: nil)
                    }
                }
                self.setTypingIndicatorVisible(typing)
            }
            .store(in: &bag)

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
                self.hasFailed = status.isFailed
                self.updateInputAvailability()
            }
            .store(in: &bag)

        Publishers.CombineLatest(session.$isReady, session.$hasEnded)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, ended in
                guard let self else { return }
                self.inputBar.isHidden = ended
                self.chatEndedView.isHidden = !ended
                self.updateInputAvailability()
                self.updateSkeletonVisibility()
                // Re-render so the in-cell suggestion row drops when the chat ends.
                if ended { self.render(self.session.messages) }
            }
            .store(in: &bag)

        network.$isOnline
            .receive(on: RunLoop.main)
            .sink { [weak self] online in self?.offlineBanner.update(isOnline: online) }
            .store(in: &bag)
    }

    // MARK: - Input availability

    private func updateInputAvailability() {
        // The composer is ALWAYS available in a live conversation — offline,
        // reconnecting, or after a terminal failure. Sending is optimistic; the
        // SDK tracks delivery (pending → failed → retry). Only the deliberate
        // ended state swaps the input bar for the "Start New" footer.
        let enabled = !session.hasEnded
        inputField.isEditable = enabled
        updateSendEnabled()
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

    // MARK: - Resume banner

    private func showResumeBannerIfNeeded() {
        guard wasResumed, !resumeBannerShown else { return }
        resumeBannerShown = true
        UIView.animate(withDuration: 0.2) {
            self.resumeBanner.isHidden = false
            self.view.layoutIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.3) {
                self.resumeBanner.isHidden = true
                self.view.layoutIfNeeded()
            }
        }
    }

    // MARK: - Sending-label delay

    private func syncSendingLabels(_ messages: [ChatMessage]) {
        for case .user(let u) in messages where u.delivery == .pending && !trackedPending.contains(u.id) {
            trackedPending.insert(u.id)
            let id = u.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                guard case .user(let current) = self.session.messages.first(where: { $0.id == id }),
                      current.delivery == .pending else { return }
                self.sendingLabels.insert(id)
                self.reconfigure(messageId: id)
            }
        }
        let stillPending = Set(messages.compactMap { msg -> UUID? in
            if case .user(let u) = msg, u.delivery == .pending { return u.id }
            return nil
        })
        sendingLabels.formIntersection(stillPending)
        trackedPending.formIntersection(stillPending)
    }

    private func reconfigure(messageId: UUID) {
        var snapshot = dataSource.snapshot()
        let item = Row.message(messageId)
        guard snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Snapshot + suggestions + typing

    private func updateSkeletonVisibility() {
        let show = !session.isReady && session.messages.isEmpty && !session.hasEnded && !hasFailed
        skeleton.isHidden = !show
        tableView.isHidden = show
    }

    private func setTypingIndicatorVisible(_ visible: Bool) {
        if visible {
            // F1: follow the typing footer in only if we're sticking to the bottom.
            let near = autoFollow
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
        // F1: follow the new content if we're sticking to the bottom (autoFollow),
        // or if the user just sent a message themselves. Otherwise the snapshot
        // lands silently and the "New messages" pill appears.
        let near = autoFollow || pendingUserSendScroll
        let forceScroll = pendingUserSendScroll
        pendingUserSendScroll = false

        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        var rows = rows(for: messages)
        // The suggestions row is appended after the last message when it carries
        // suggestions, so it appears (and disappears) as a row insert/delete.
        if let suggestionId = suggestionMessageId(in: messages) {
            rows.append(.suggestions(suggestionId))
        }
        snapshot.appendItems(rows)
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let toReconfigure = rows.filter { existing.contains($0) }
        if !toReconfigure.isEmpty { snapshot.reconfigureItems(toReconfigure) }
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
            scrollTableToBottom(animated: animated)
        } else {
            hasNewBelow = true
        }
    }

    /// The last message overall, when it carries suggestions and the chat is
    /// still live — mirrors SwiftUI ChatView (`isLast && hasSuggestions && !ended`).
    private func suggestionMessageId(in messages: [ChatMessage]) -> UUID? {
        guard !session.hasEnded, let last = messages.last, !last.suggestions.isEmpty else { return nil }
        return last.id
    }

    private func scrollTableToBottom(animated: Bool) {
        tableView.layoutIfNeeded()
        // When the typing footer is present it sits below the last row, so scroll
        // to the true content bottom; otherwise scrollToRow is the most reliable
        // against self-sizing estimates.
        if (tableView.tableFooterView?.bounds.height ?? 0) > 1 {
            let minOffsetY = -tableView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            tableView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: animated)
        } else {
            let count = tableView.numberOfRows(inSection: 0)
            guard count > 0 else { return }
            tableView.scrollToRow(at: IndexPath(row: count - 1, section: 0), at: .bottom, animated: animated)
        }
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
        // F1: the local user just sent — snap to the bottom on the next render and
        // resume following so the agent's reply scrolls in while they wait.
        autoFollow = true
        pendingUserSendScroll = true
        Task { try? await session.send(text) }
    }

    private func startNewConversationInPlace() {
        session.clearChat()
        Task { try? await session.client.startNewSession() }
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
        // SDK throttles STARTED frames to <=1/3s — safe on every keystroke.
        if !textView.text.isEmpty {
            Task { await session.sendTyping() }
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

// MARK: - TimestampCell

private final class TimestampCell: UITableViewCell {
    static let reuseID = "TimestampCell"
    private let label = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String) { label.text = text }
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
        avatar.load(url: url, fallback: UIImage(systemName: "person.circle.fill"))
    }
}
