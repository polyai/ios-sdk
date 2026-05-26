// Copyright PolyAI Limited

//  TerminalErrorScreen.swift
//  Examples/UIKit/04-Resilience
//
//  Mirrors README:
//    - § "Best practices > Surface .failed with a manual retry"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

/// Full-screen replacement for the chat UI when the SDK has given up
/// reconnecting (`session.failureReason != nil`). The user gets one big
/// "Reconnect" button that calls `client.resume()` — that's the README
/// "Best practices > Surface .failed with a manual retry" pattern.
final class TerminalErrorScreen: UIView {

    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let reasonLabel = UILabel()
    private let reconnectButton = UIButton(type: .system)

    private var onReconnect: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// Configure the screen with the failure reason + a retry callback.
    /// The callback should call `session.client.resume()` (wrapped in a Task).
    func configure(reason: PolyError, onReconnect: @escaping () -> Void) {
        self.onReconnect = onReconnect
        // PolyError does NOT conform to LocalizedError, so
        // .localizedDescription would just be Error's default
        // ("The operation couldn't be completed…"). String(describing:)
        // gives the case name + associated values, which is far more
        // useful for an example.
        reasonLabel.text = String(describing: reason)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .systemBackground

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = .init(pointSize: 48, weight: .regular)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Couldn't connect"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        reasonLabel.translatesAutoresizingMaskIntoConstraints = false
        reasonLabel.font = .preferredFont(forTextStyle: .subheadline)
        reasonLabel.textColor = .secondaryLabel
        reasonLabel.numberOfLines = 0
        reasonLabel.textAlignment = .center

        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        var conf = UIButton.Configuration.borderedProminent()
        conf.title = "Reconnect"
        conf.buttonSize = .large
        reconnectButton.configuration = conf
        reconnectButton.addTarget(self, action: #selector(reconnectTapped), for: .touchUpInside)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        addSubview(stack)

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(reasonLabel)
        // The reconnect button is added outside the centred stack so we can
        // pin it to the bottom with generous insets.
        addSubview(reconnectButton)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            reconnectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            reconnectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            reconnectButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
    }

    @objc private func reconnectTapped() {
        onReconnect?()
    }
}
