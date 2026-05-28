// Copyright PolyAI Limited

//  OfflineBanner.swift
// Examples/UIKit/05-Handoff
//
//  Mirrors README:
//    - § "What you can build > Connection monitoring"
//

import UIKit

/// Bar pinned above the chat when device connectivity is lost.
/// Distinct from the SDK's reconnect banner (which fires on WebSocket drop).
///
/// Style mirrors the SwiftUI reference: translucent red bg, `wifi.slash`
/// icon + bold red label, full-width, 6pt vertical padding.
final class OfflineBanner: UIView {

    private let iconView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.systemRed.withAlphaComponent(0.18)
        isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "wifi.slash")
        iconView.tintColor = .systemRed
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "You're offline"
        label.textColor = .systemRed
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textAlignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(isOnline: Bool) {
        isHidden = isOnline
    }
}
