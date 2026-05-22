//  ErrorViewController.swift
//  Examples/UIKit/07-Playground
//
//  Recoverable startup / session failure screen. Mirrors the SwiftUI 06
//  `ErrorScreen`: warning glyph, message, and a "Go Back" button that returns
//  to the connect screen so the user can resume or start fresh.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

final class ErrorViewController: UIViewController {

    private let message: String
    private let onBack: () -> Void

    init(message: String, onBack: @escaping () -> Void) {
        self.message = message
        self.onBack = onBack
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .systemOrange
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(icon)

        let title = UILabel()
        title.text = "Something went wrong"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)

        var config = UIButton.Configuration.filled()
        config.title = "Go Back"
        config.cornerStyle = .medium
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.onBack()
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            messageLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            button.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -32),
        ])
    }
}
