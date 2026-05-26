//  ChatViewController.swift
//  Examples/UIKit/01-Hello
//
//  Mirrors README:
//    - § "Get started > Use in your app > UIKit"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import Combine
import PolyMessaging

final class ChatViewController: UIViewController {

    // Wired in Main.storyboard.
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var inputField: UITextField!
    @IBOutlet weak var sendButton: UIButton!

    // Store one ChatSession per chat surface — don't recreate on appearance.
    private var session: ChatSession!
    private var bag = Set<AnyCancellable>()

    // Diffable data source keyed by ChatMessage.id (UUID).
    private var dataSource: UITableViewDiffableDataSource<Int, UUID>!

    override func viewDidLoad() {
        super.viewDidLoad()
        session = PolyMessaging.chat()
        applyKeyboardAvoidance()
        configureDataSource()
        bind()

        // The storyboard already styles the composer (rounded text field + "Send"
        // button). All we add in code is the accessibility identifiers the UITests
        // query, and disabling Send while the field is empty.
        inputField.accessibilityIdentifier = "composer"
        sendButton.accessibilityIdentifier = "sendButton"
        inputField.addAction(UIAction { [weak self] _ in
            self?.updateSendEnabled()
        }, for: .editingChanged)
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
        let hasText = !(inputField.text?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        sendButton.isEnabled = hasText && !session.hasEnded
    }

    private func configureDataSource() {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        dataSource = UITableViewDiffableDataSource<Int, UUID>(tableView: tableView) {
            [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            let message = self?.session.messages.first(where: { $0.id == id })
            cell.textLabel?.text = message?.text ?? ""
            cell.textLabel?.numberOfLines = 0
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
        // can't auto-recover from — most notably an invalid `connectorToken`.
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
        // PolyError doesn't conform to LocalizedError — String(describing:) gives
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
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        let ids = messages.map(\.id)
        snapshot.appendItems(ids)
        let existing = dataSource.snapshot().itemIdentifiers
        let toReconfigure = ids.filter { existing.contains($0) }
        if !toReconfigure.isEmpty {
            snapshot.reconfigureItems(toReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    @IBAction func sendTapped(_ sender: Any) {
        guard let text = inputField.text, !text.isEmpty else { return }
        inputField.text = ""
        updateSendEnabled()
        Task { try? await self.session.send(text) }
    }
}
