// Copyright PolyAI Limited

//  TerminalErrorScreen.swift
//  Examples/UIKit/05-Handoff
//
//  Mirrors README:
//    - § "Best practices > Surface .failed with a manual retry"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

/// Full-bleed screen for errors that aren't recoverable by reconnect —
/// auth failures, configuration mistakes, dead sessions, etc.
final class TerminalErrorScreen: UIView {

    private let messageLabel = UILabel()
    private let button = UIButton(type: .system)
    var onStartNew: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .systemBackground
        isHidden = true

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        let title = UILabel()
        title.text = "Something went wrong"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        var config = UIButton.Configuration.borderedProminent()
        config.title = "Start New Chat"
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak self] _ in self?.onStartNew?() }, for: .touchUpInside)
        addSubview(button)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -60),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),

            messageLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            button.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(message: String) {
        messageLabel.text = message
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}
