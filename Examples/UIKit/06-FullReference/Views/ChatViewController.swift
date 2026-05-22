//  ChatViewController.swift
//  Examples/UIKit/06-FullReference
//
//  The full chat surface, mirroring the SwiftUI 06 ChatView + ChatScreen:
//  message list, offline + reconnecting bars, typing footer, suggestion pills,
//  delivery tracking with a 500ms-delayed "Sending..." label, a chat-ended
//  banner with in-place start-new, and a resume banner shown briefly when a
//  prior conversation was restored.
//
//  Unlike L05 this controller is handed a ChatSession by RootViewController
//  instead of creating its own — the connect / loading / error shell and the
//  nav-bar End / back buttons live in RootViewController.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import Combine
import PolyMessaging

final class ChatViewController: UIViewController {

    static let maxMessageLength = 500

    private let session: ChatSession
    private let wasResumed: Bool
    private var bag = Set<AnyCancellable>()

    private let network = NetworkMonitor()

    // The list interleaves message bubbles with an optional suggestions row, so
    // suggestions scroll inside the table without ever changing a bubble's height
    // (in-cell suggestions made reconfigured cells keep a stale, taller height).
    private enum Row: Hashable {
        case message(UUID)
        case suggestions(UUID)
    }
    private var dataSource: UITableViewDiffableDataSource<Int, Row>!

    // Delayed "Sending..." label state (SwiftUI ChatScreen.syncSendingLabels).
    private var sendingLabels: Set<UUID> = []
    private var trackedPending: Set<UUID> = []

    private var hasFailed = false
    private var resumeBannerShown = false

    // Programmatic views.
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
    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let chatEndedView = UIView()

    init(session: ChatSession, wasResumed: Bool) {
        self.session = session
        self.wasResumed = wasResumed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        layoutUI()
        configureDataSource()
        bind()
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
        // Banners live in a vertical stack pinned to the safe-area top. A stack
        // collapses hidden arranged subviews, so when no banner is showing the
        // table reaches the top with no reserved padding (safe area is kept).
        let bannerStack = UIStackView(arrangedSubviews: [resumeBanner, offlineBanner, connectionBanner])
        bannerStack.axis = .vertical
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bannerStack)
        view.addSubview(tableView)
        view.addSubview(skeleton)
        view.addSubview(inputBar)
        view.addSubview(chatEndedView)

        configureResumeBanner()
        configureConnectionBanner()
        configureTableView()
        configureTypingFooter()
        configureInputBar()
        configureChatEndedView()

        resumeBanner.isHidden = true
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bannerStack.topAnchor.constraint(equalTo: safe.topAnchor),
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
            inputBar.heightAnchor.constraint(equalToConstant: 60),

            chatEndedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatEndedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatEndedView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
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
        tableView.register(SuggestionsCell.self, forCellReuseIdentifier: SuggestionsCell.reuseID)
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

    private func configureInputBar() {
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.backgroundColor = .systemBackground

        inputBarBorder.translatesAutoresizingMaskIntoConstraints = false
        inputBarBorder.backgroundColor = .separator
        inputBar.addSubview(inputBarBorder)

        inputFieldBackground.translatesAutoresizingMaskIntoConstraints = false
        inputFieldBackground.backgroundColor = .systemGray6
        inputFieldBackground.layer.cornerRadius = 22
        inputFieldBackground.layer.masksToBounds = true
        inputBar.addSubview(inputFieldBackground)

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholder = "Message..."
        inputField.accessibilityIdentifier = "composer"
        inputField.borderStyle = .none
        inputField.font = .systemFont(ofSize: 15)
        inputField.returnKeyType = .send
        inputField.delegate = self
        inputFieldBackground.addSubview(inputField)

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

        NSLayoutConstraint.activate([
            inputBarBorder.topAnchor.constraint(equalTo: inputBar.topAnchor),
            inputBarBorder.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            inputBarBorder.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),
            inputBarBorder.heightAnchor.constraint(equalToConstant: 0.5),

            inputFieldBackground.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: 12),
            inputFieldBackground.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
            inputFieldBackground.heightAnchor.constraint(equalToConstant: 44),
            inputFieldBackground.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            inputField.leadingAnchor.constraint(equalTo: inputFieldBackground.leadingAnchor, constant: 14),
            inputField.trailingAnchor.constraint(equalTo: inputFieldBackground.trailingAnchor, constant: -14),
            inputField.centerYAnchor.constraint(equalTo: inputFieldBackground.centerYAnchor),

            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        inputField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.enforceMaxLength()
            self.updateSendEnabled()
            // SDK throttles STARTED frames to <=1/3s — safe on every keystroke.
            if !(self.inputField.text ?? "").isEmpty {
                Task { await self.session.sendTyping() }
            }
        }, for: .editingChanged)
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
            case .message(let id):
                let cell = tableView.dequeueReusableCell(withIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
                if let message = self.session.messages.first(where: { $0.id == id }) {
                    cell.configure(with: message, showSendingLabel: self.sendingLabels.contains(id))
                    cell.onRetry = { [weak self] text in
                        if let draftId = self?.draftId(for: id) { self?.session.removeMessage(draftId: draftId) }
                        Task { try? await self?.session.send(text) }
                    }
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

    private func draftId(for id: UUID) -> String? {
        guard case .user(let u) = session.messages.first(where: { $0.id == id }) else { return nil }
        return u.draftId
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
        inputField.isEnabled = enabled
        updateSendEnabled()
    }

    private func updateSendEnabled() {
        let enabled = !session.hasEnded
        let hasText = !(inputField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        sendButton.isEnabled = enabled && hasText
    }

    private func enforceMaxLength() {
        guard let text = inputField.text, text.count > Self.maxMessageLength else { return }
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

    // MARK: - Sending-label delay (mirrors SwiftUI ChatScreen.syncSendingLabels)

    private func syncSendingLabels(_ messages: [ChatMessage]) {
        for case .user(let u) in messages where u.delivery == .pending && !trackedPending.contains(u.id) {
            trackedPending.insert(u.id)
            let id = u.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                guard case .user(let current) = self.session.messages.first(where: { $0.id == id }),
                      current.delivery == .pending else { return }
                self.sendingLabels.insert(id)
                self.reconfigure(id: id)
            }
        }
        let stillPending = Set(messages.compactMap { msg -> UUID? in
            if case .user(let u) = msg, u.delivery == .pending { return u.id }
            return nil
        })
        sendingLabels.formIntersection(stillPending)
        trackedPending.formIntersection(stillPending)
    }

    private func reconfigure(id: UUID) {
        var snapshot = dataSource.snapshot()
        let item = Row.message(id)
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
            updateTypingFooterFrame()
            tableView.tableFooterView = typingFooter
            typingIndicator.start()
            scrollTableToBottom(animated: true)
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
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        var rows = messages.map { Row.message($0.id) }
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
            self?.scrollTableToBottom(animated: true)
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
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        inputField.text = ""
        updateSendEnabled()
        Task { try? await session.send(text) }
    }

    private func startNewConversationInPlace() {
        session.clearChat()
        Task { try? await session.client.startNewSession() }
    }
}

// MARK: - UITextFieldDelegate

extension ChatViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendCurrentText()
        return false
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
        avatar.load(url: url, fallback: UIImage(systemName: "person.circle.fill"))
    }
}
