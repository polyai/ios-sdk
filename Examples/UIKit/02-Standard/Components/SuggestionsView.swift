// Copyright PolyAI Limited

//  SuggestionsView.swift
// Examples/UIKit/02-Standard
//
//  Mirrors README:
//    - § "What you can build > Quick reply suggestions"
//
//  Horizontally scrollable pill row. Call update(suggestions:onTap:) with the
//  most recent agent message's suggestions. Empty array hides the view.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

final class SuggestionsView: UIView {

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var onTap: ((ResponseSuggestion) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(suggestions: [ResponseSuggestion], onTap: @escaping (ResponseSuggestion) -> Void) {
        self.onTap = onTap
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = suggestions.isEmpty
        for suggestion in suggestions {
            stack.addArrangedSubview(makePill(for: suggestion))
        }
    }

    private func makePill(for suggestion: ResponseSuggestion) -> UIButton {
        // Borderless capsule pill matching SwiftUI SuggestionRow:
        // translucent blue background + blue title, no stroke.
        var config = UIButton.Configuration.filled()
        config.title = suggestion.messageText
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        config.baseForegroundColor = .systemBlue
        config.background.strokeWidth = 0
        config.background.strokeColor = .clear
        config.contentInsets = .init(top: 6, leading: 14, bottom: 6, trailing: 14)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.onTap?(suggestion)
        })
        // Accessibility: each pill is an individually focusable interactive
        // control. The stable identifier lets UITests query the pills, and the
        // label gives VoiceOver a clear "Suggested reply: …" announcement.
        button.accessibilityIdentifier = "suggestionPill"
        button.accessibilityLabel = "Suggested reply: \(suggestion.messageText)"
        return button
    }
}
