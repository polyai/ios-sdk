// Copyright PolyAI Limited

//  ConnectViewController.swift
//  Examples/UIKit/07-Playground
//
//  Entry screen for resume-versus-fresh, playground flavour. Like the 06
//  connect screen but the environment label is resolved live from DevSettings
//  and a badge shows when custom dev settings are active. The Dev Settings gear
//  lives in the nav bar (owned by RootViewController).
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

final class ConnectViewController: UIViewController {

    private let hasActiveSession: Bool
    private let canResume: Bool
    private let environmentLabel: String
    private let hasCustomSettings: Bool
    private let onResume: () -> Void
    private let onStartNew: () -> Void

    init(hasActiveSession: Bool, canResume: Bool, environmentLabel: String, hasCustomSettings: Bool,
         onResume: @escaping () -> Void, onStartNew: @escaping () -> Void) {
        self.hasActiveSession = hasActiveSession
        self.canResume = canResume
        self.environmentLabel = environmentLabel
        self.hasCustomSettings = hasCustomSettings
        self.onResume = onResume
        self.onStartNew = onStartNew
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        scroll.addSubview(stack)

        let glyph = UIImageView(image: UIImage(systemName: "ladybug.fill"))
        glyph.tintColor = .systemBlue
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let title = UILabel()
        title.text = "PolyMessaging Playground"
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textAlignment = .center
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = "Protocol & lifecycle testing"
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center

        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(28, after: subtitle)

        stack.addArrangedSubview(makeInfoCard())

        if hasCustomSettings {
            let badge = UILabel()
            badge.text = "⚙︎ Custom dev settings active"
            badge.font = .preferredFont(forTextStyle: .caption1)
            badge.textColor = .systemOrange
            badge.textAlignment = .center
            stack.addArrangedSubview(badge)
        }

        let primaryShowsResume = hasActiveSession || canResume
        var primaryConfig = UIButton.Configuration.filled()
        primaryConfig.title = primaryShowsResume ? "Resume Chat" : "Start Chat"
        primaryConfig.image = UIImage(systemName: primaryShowsResume ? "arrow.uturn.forward.circle.fill" : "bolt.fill")
        primaryConfig.imagePadding = 8
        primaryConfig.cornerStyle = .large
        primaryConfig.buttonSize = .large
        let primary = UIButton(configuration: primaryConfig, primaryAction: UIAction { [weak self] _ in
            self?.onResume()
        })
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last ?? subtitle)
        stack.addArrangedSubview(primary)

        if primaryShowsResume {
            var secondaryConfig = UIButton.Configuration.gray()
            secondaryConfig.title = "Start New Chat"
            secondaryConfig.cornerStyle = .large
            secondaryConfig.baseForegroundColor = .systemBlue
            let secondary = UIButton(configuration: secondaryConfig, primaryAction: UIAction { [weak self] _ in
                self?.onStartNew()
            })
            stack.addArrangedSubview(secondary)
        }

        let statusLabel = UILabel()
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = UIColor.systemBlue.withAlphaComponent(0.8)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        if hasActiveSession {
            statusLabel.text = "Your conversation is still active"
        } else if canResume {
            statusLabel.text = "A previous conversation is available to resume"
        }
        stack.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private func makeInfoCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false

        let envRow = makeRow(icon: "server.rack", caption: "ENVIRONMENT", value: environmentLabel, monospaced: false)
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        let connectorRow = makeRow(icon: "key.fill", caption: "CONNECTOR",
                                   value: "dev connector", monospaced: true)

        let cardStack = UIStackView(arrangedSubviews: [envRow, divider, connectorRow])
        cardStack.axis = .vertical
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        return card
    }

    private func makeRow(icon: String, caption: String, value: String, monospaced: Bool) -> UIStackView {
        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let captionLabel = UILabel()
        captionLabel.text = caption
        captionLabel.font = .preferredFont(forTextStyle: .caption2)
        captionLabel.textColor = .secondaryLabel

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = monospaced
            ? .monospacedSystemFont(ofSize: 15, weight: .regular)
            : .systemFont(ofSize: 15, weight: .medium)
        valueLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = UIStackView(arrangedSubviews: [captionLabel, valueLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [iconView, textStack])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        return row
    }
}
