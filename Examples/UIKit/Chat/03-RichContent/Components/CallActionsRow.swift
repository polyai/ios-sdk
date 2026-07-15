// Copyright PolyAI Limited

//  CallActionsRow.swift
// Examples/UIKit/03-RichContent
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//

import UIKit
import PolyMessaging

/// A vertical stack of green "Call …" buttons. Each one opens a tel:// URL
/// with non-digit characters stripped (preserving leading +) so numbers
/// formatted like "+1 (415) 555-1212" still dial correctly.
final class CallActionsRow: UIView {

    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(actions: [ChatCallAction]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            stack.addArrangedSubview(makeButton(for: action))
        }
        isHidden = actions.isEmpty
    }

    private func makeButton(for action: ChatCallAction) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = action.title.isEmpty ? action.contactNumber : action.title
        config.image = UIImage(systemName: "phone.fill")
        config.imagePadding = 6
        config.baseBackgroundColor = .systemGreen
        config.baseForegroundColor = .white
        config.cornerStyle = .medium

        let digits = action.contactNumber.filter { $0.isNumber || $0 == "+" }
        let url = URL(string: "tel:\(digits)")

        let button = UIButton(configuration: config, primaryAction: UIAction { _ in
            if let url { UIApplication.shared.open(url) }
        })
        button.isEnabled = (url != nil)
        return button
    }
}
