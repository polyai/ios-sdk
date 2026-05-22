//  URLCardView.swift
// Examples/UIKit/07-Playground
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import PolyMessaging

/// Card view for ATTACHMENT_CONTENT_TYPE_URL — surfaces a preview image,
/// a title, and a CTA. Tapping opens the URL externally.
final class URLCardView: UIView {

    private let preview = RetryableImageView()
    private let titleLabel = UILabel()
    private let ctaLabel = UILabel()
    private var openURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.masksToBounds = true
        isUserInteractionEnabled = true

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.layer.cornerRadius = 8
        preview.contentMode = .scaleAspectFill
        addSubview(preview)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 2
        addSubview(titleLabel)

        ctaLabel.translatesAutoresizingMaskIntoConstraints = false
        ctaLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        ctaLabel.textColor = .systemBlue
        addSubview(ctaLabel)

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            preview.widthAnchor.constraint(equalToConstant: 56),
            preview.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            ctaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            ctaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            ctaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            ctaLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with attachment: Attachment) {
        openURL = attachment.contentUrl
        titleLabel.text = attachment.title?.isEmpty == false ? attachment.title : (attachment.contentUrl?.host ?? "")
        if let cta = attachment.callToActionText, !cta.isEmpty {
            ctaLabel.text = cta
        } else if let host = attachment.contentUrl?.host {
            ctaLabel.text = host
            ctaLabel.textColor = .secondaryLabel
        } else {
            ctaLabel.text = ""
        }
        preview.load(url: attachment.previewImageUrl, fallback: UIImage(systemName: "link"))
    }

    @objc private func open() {
        guard let openURL else { return }
        UIApplication.shared.open(openURL)
    }
}
