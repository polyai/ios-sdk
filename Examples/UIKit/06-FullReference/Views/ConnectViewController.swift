// Copyright PolyAI Limited

//  ConnectViewController.swift
//  Examples/UIKit/06-FullReference
//
//  Entry screen for resume-versus-fresh. Mirrors the SwiftUI 06 `ConnectView`:
//  an environment/connector info card plus a primary "Resume / Start" button
//  and a secondary "Start New Chat" when a resumable session exists. Both
//  paths stay visible so host apps can copy the exact flow they need.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

final class ConnectViewController: UIViewController {

    private let hasActiveSession: Bool
    private let canResume: Bool
    private let onResume: () -> Void
    private let onStartNew: () -> Void

    init(hasActiveSession: Bool, canResume: Bool,
         onResume: @escaping () -> Void, onStartNew: @escaping () -> Void) {
        self.hasActiveSession = hasActiveSession
        self.canResume = canResume
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

        // Header glyph + titles.
        let glyph = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right.fill"))
        glyph.tintColor = .systemBlue
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let title = UILabel()
        title.text = "PolyMessaging"
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "AI-powered conversations"
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center

        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(28, after: subtitle)

        stack.addArrangedSubview(makeInfoCard())

        // Primary button — Resume vs Start.
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
        stack.setCustomSpacing(28, after: stack.arrangedSubviews.last ?? subtitle)
        stack.addArrangedSubview(primary)

        // Secondary "Start New Chat" when a session is resumable.
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

        // Status footer.
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

        let version = UILabel()
        version.text = "PolyMessaging iOS SDK v\(PolyMessaging.version)"
        version.font = .preferredFont(forTextStyle: .caption2)
        version.textColor = UIColor.secondaryLabel.withAlphaComponent(0.6)
        version.textAlignment = .center
        stack.addArrangedSubview(version)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 40),
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

        let envRow = makeRow(
            icon: "server.rack",
            caption: "ENVIRONMENT",
            value: "messaging.dev.poly.ai",
            valueMonospaced: false
        )
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = .systemGreen
        dot.layer.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        envRow.addArrangedSubview(dot)

        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        let connectorRow = makeRow(
            icon: "key.fill",
            caption: "CONNECTOR",
            value: "dev connector",
            valueMonospaced: true
        )

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

    private func makeRow(icon: String, caption: String, value: String, valueMonospaced: Bool) -> UIStackView {
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
        valueLabel.font = valueMonospaced
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
