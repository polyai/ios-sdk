// Copyright PolyAI Limited

//  ChatViewController.swift
//  Examples/UIKit/05-Handoff
//
//  Mirrors README:
//    - § "Use in your app > UIKit"
//    - § "What you can build > Live agent handoff"
//    - § "Get started > Listen for events"
//

import UIKit
import Combine
import PolyMessaging

final class ChatViewController: UIViewController {

    // Only the End button is wired in the Storyboard.
    @IBOutlet weak var endButton: UIBarButtonItem?
    private var endButtonRef: UIBarButtonItem?

    // One ChatSession per chat surface — don't recreate on appearance.
    private var session: ChatSession!
    private var bag = Set<AnyCancellable>()

    /// Cancelled in `deinit` so the for-await loop exits when we go away.
    private var eventTask: Task<Void, Never>?

    private let network = NetworkMonitor()
    // Rows: each message, plus a suggestions pill-row appended under the last
    // agent message (mirrors 06 — pills live in the list, not pinned above input).
    private enum Row: Hashable {
        case message(UUID)
        case suggestions(UUID)
    }
    private var dataSource: UITableViewDiffableDataSource<Int, Row>!

    // Programmatic views.
    private let bannerStack = UIStackView()
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
    private let inputField = UITextField()
    private let sendButton = UIButton(type: .system)
    private let failureOverlay = UIView()
    private let failureLabel = UILabel()
    private let chatEndedView = UIView()
    private let terminalScreen = TerminalErrorScreen()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Chat"
        session = PolyMessaging.chat()
        endButtonRef = navigationItem.rightBarButtonItem
        layoutUI()
        configureDataSource()
        bind()
        startEventTask()
    }

    deinit { eventTask?.cancel() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTypingFooterFrame()
    }

    // MARK: - Layout

    private func layoutUI() {
        // Banners sit in a stack pinned to the safe-area top. A stack collapses
        // hidden arranged subviews, so the table reaches the top with no reserved
        // padding when neither banner is showing (safe area is kept).
        bannerStack.axis = .vertical
        bannerStack.translatesAutoresizingMaskIntoConstraints = false
        bannerStack.addArrangedSubview(offlineBanner)
        bannerStack.addArrangedSubview(connectionBanner)
        view.addSubview(bannerStack)
        view.addSubview(tableView)
        view.addSubview(skeleton)
        view.addSubview(inputBar)
        view.addSubview(chatEndedView)
        view.addSubview(failureOverlay)
        view.addSubview(terminalScreen)

        configureConnectionBanner()
        configureTableView()
        configureTypingFooter()
        configureInputBar()
        configureChatEndedView()
        configureFailureOverlay()
        terminalScreen.onStartNew = { [weak self] in
            self?.title = "Chat"
            Task { try? await self?.session.client.startNewSession() }
        }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bannerStack.topAnchor.constraint(equalTo: safe.topAnchor),
            bannerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bannerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: bannerStack.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            skeleton.topAnchor.constraint(equalTo: tableView.topAnchor),
            skeleton.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),

            // Suggestions now render as a list row, so the table pins straight to
            // the composer.
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            inputBar.heightAnchor.constraint(equalToConstant: 60),

            chatEndedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatEndedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chatEndedView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            failureOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            failureOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            failureOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            terminalScreen.topAnchor.constraint(equalTo: view.topAnchor),
            terminalScreen.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminalScreen.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalScreen.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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

        // Rounded text field — .roundedRect gives the standard composer look
        // without a separate background view to style and pin.
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholder = "Message..."
        inputField.accessibilityIdentifier = "composer"
        inputField.borderStyle = .roundedRect
        inputBar.addSubview(inputField)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.accessibilityIdentifier = "sendButton"
        var sconf = UIButton.Configuration.plain()
        sconf.image = UIImage(systemName: "arrow.up.circle.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 36))
        sconf.baseForegroundColor = .systemBlue
        sconf.contentInsets = .zero
        sendButton.configuration = sconf
        // No configurationUpdateHandler needed — UIButton dims a disabled symbol automatically.
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        inputBar.addSubview(sendButton)

        NSLayoutConstraint.activate([
            inputBarBorder.topAnchor.constraint(equalTo: inputBar.topAnchor),
            inputBarBorder.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            inputBarBorder.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),
            inputBarBorder.heightAnchor.constraint(equalToConstant: 0.5),

            inputField.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: 12),
            inputField.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
            inputField.heightAnchor.constraint(equalToConstant: 44),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputBar.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        // SDK throttles STARTED frames to ≤1/3s — safe on every keystroke.
        inputField.addAction(UIAction { [weak self] _ in
            Task { await self?.session.sendTyping() }
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
            self?.title = "Chat"
            Task { try? await self?.session.client.startNewSession() }
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

    private func configureFailureOverlay() {
        failureOverlay.translatesAutoresizingMaskIntoConstraints = false
        failureOverlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        failureOverlay.isHidden = true

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

        var rc = UIButton.Configuration.borderedProminent()
        rc.title = "Reconnect"
        let reconnect = UIButton(configuration: rc, primaryAction: UIAction { [weak self] _ in
            Task { try? await self?.session.client.resume() }
        })
        reconnect.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(reconnect)

        NSLayoutConstraint.activate([
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
            reconnect.topAnchor.constraint(equalTo: failureLabel.bottomAnchor, constant: 16),
            reconnect.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            reconnect.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
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
                    cell.configure(with: message)
                    cell.onRetry = { [weak self] text in
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

    // MARK: - Bindings

    private func bind() {
        session.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                guard let self else { return }
                self.render(messages)
                self.updateSkeletonVisibility()
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

        session.$failureReason
            .receive(on: RunLoop.main)
            .sink { [weak self] reason in
                guard let self else { return }
                guard let reason else {
                    self.failureOverlay.isHidden = true
                    self.terminalScreen.hide()
                    return
                }
                // falls back to Error's generic default. Use String(describing:).
                let message = String(describing: reason)
                if Self.isTerminal(reason) {
                    self.terminalScreen.show(message: message)
                    self.failureOverlay.isHidden = true
                } else {
                    self.failureOverlay.isHidden = false
                    self.failureLabel.text = message
                }
            }
            .store(in: &bag)

        // Composing stays available while offline/reconnecting — the SDK sends
        // optimistically and tracks delivery (pending → failed → retry). Gate the
        // composer on hasEnded only, never on connection readiness.
        session.$hasEnded
            .receive(on: RunLoop.main)
            .sink { [weak self] ended in
                guard let self else { return }
                self.sendButton.isEnabled = !ended
                self.inputField.isEnabled = !ended
                self.navigationItem.rightBarButtonItem = ended ? nil : self.endButtonRef
                self.inputBar.isHidden = ended
                self.chatEndedView.isHidden = !ended
                self.updateSkeletonVisibility()
                // Re-render so the suggestions row drops when the chat ends.
                if ended { self.render(self.session.messages) }
            }
            .store(in: &bag)

        network.$isOnline
            .receive(on: RunLoop.main)
            .sink { [weak self] online in self?.offlineBanner.update(isOnline: online) }
            .store(in: &bag)
    }

    /// README "Listen for events > UIKit". Cancelled in `deinit`.
    private func startEventTask() {
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.session.client.events {
                self.handle(event: event)
            }
        }
    }

    private func handle(event: MessagingEvent) {
        switch event {
        case .liveAgentJoined(_, let p):
            title = (p.agentName?.isEmpty == false) ? p.agentName : "Chat"
        case .clientHandoffRequired(_, let p):
            // Optionally deep-link if the route parses as http(s).
            if let route = p.route, let url = URL(string: route),
               let scheme = url.scheme, scheme.hasPrefix("http") {
                UIApplication.shared.open(url)
            }
        case .liveAgentLeft:
            title = "Chat"
        case .sessionStart:
            title = "Chat"
        default:
            // Handoff progress events flow through session.messages as
            // SystemMessage pills. .liveAgentTyping is rendered via
            // session.isAgentTyping, and .liveAgentMessage flows into
            // session.messages as an AgentMessage with agentKind == .live.
            break
        }
    }

    // MARK: - Snapshot + suggestions

    private func updateSkeletonVisibility() {
        let show = !session.isReady && session.messages.isEmpty && !session.hasEnded
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
        // Suggestions render as their own row under the last agent message, so
        // showing/hiding them never resizes a bubble cell (mirrors 06).
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

    @objc private func sendTapped() {
        guard let text = inputField.text, !text.isEmpty else { return }
        inputField.text = ""
        Task { try? await self.session.send(text) }
    }

    @IBAction func endTapped(_ sender: Any) {
        Task { try? await self.session.end() }
    }

    /// Auth/config/expired-session errors are terminal — show the big screen
    /// instead of the reconnect card.
    private static func isTerminal(_ error: PolyError) -> Bool {
        if error.isRetryable { return false }
        switch error {
        case .invalidConfiguration, .auth: return true
        case .session(.sessionExpired), .session(.sessionEnded), .session(.sessionCreationFailed):
            return true
        default: return false
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
        avatar.load(url: url, fallback: UIImage(systemName: "person.circle.fill"))
    }
}
