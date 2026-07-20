// Copyright PolyAI Limited

//  AttachmentCarouselView.swift
// Examples/UIKit/03-RichContent
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//

import UIKit
import PolyMessaging

/// Horizontally scrolling list of image attachments attached to an agent
/// message. Each card is 220 wide: 140pt preview on top, optional title +
/// CTA section underneath (10pt padding). Tapping a card opens its
/// `contentUrl` externally.
///
/// Visually 1-1 with the SwiftUI `AttachmentCarousel`: 10pt card spacing,
/// 4pt padding around the strip, an 8pt title→CTA gap, a `systemGray6`
/// loading backdrop, and a centered photo icon on a `systemGray4`
/// rectangle as the failed-load fallback.
final class AttachmentCarouselView: UIView {

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    // Fallback width (one card) used only when the host doesn't size the
    // carousel. The host (MessageCell) pins a wider, content-relative width at
    // a higher priority so cards show side by side (SwiftUI parity); this
    // default just keeps the view unambiguous on its own.
    private lazy var widthConstraint: NSLayoutConstraint = {
        let c = widthAnchor.constraint(equalToConstant: 228)
        c.priority = .defaultHigh
        return c
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        // Accessibility/UITest hook: a stable identifier so the carousel can be
        // located in the view tree (mirrors the SwiftUI "attachmentCarousel").
        scrollView.accessibilityIdentifier = "attachmentCarousel"
        addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        // SwiftUI parity: HStack(spacing: 10).
        stack.spacing = 10
        stack.alignment = .top
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // SwiftUI parity: 4pt padding on all sides of the strip
            // (.padding(.horizontal, 4).padding(.vertical, 4)). The insets live
            // on the stack inside the contentLayoutGuide; tying the viewport
            // height to the content height makes the carousel hug the tallest
            // card plus the 4pt vertical padding (image-only vs image+text).
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -4),
            scrollView.frameLayoutGuide.heightAnchor.constraint(equalTo: scrollView.contentLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with attachments: [Attachment]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Guard the isHidden write. Setting an arranged subview's isHidden to a
        // value it already holds corrupts UIStackView's hidden bookkeeping, so a
        // later un-hide silently no-ops — the carousel then stays collapsed,
        // the host MessageCell sizes to its text only, and the image card spills
        // out of the cell, covering the rows below (suggestions / next message).
        // Writing only on a real change keeps the strip's show/hide reliable.
        let shouldHide = attachments.isEmpty
        if isHidden != shouldHide { isHidden = shouldHide }
        widthConstraint.isActive = !attachments.isEmpty
        for attachment in attachments {
            stack.addArrangedSubview(makeCard(for: attachment))
        }
    }

    private func makeCard(for attachment: Attachment) -> UIView {
        let card = UIControl()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .systemGray6
        card.layer.cornerRadius = 12
        card.layer.masksToBounds = true
        // SwiftUI parity: .disabled(attachment.contentUrl == nil).
        card.isEnabled = attachment.contentUrl != nil

        // Vertical body stack lets the card height follow its content
        // (image-only vs image + text) like SwiftUI's VStack(spacing: 0).
        let body = UIStackView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.axis = .vertical
        body.spacing = 0
        // Let taps fall through to the card so the whole card is the button.
        body.isUserInteractionEnabled = false
        card.addSubview(body)

        let preview = RetryableImageView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.contentMode = .scaleAspectFill
        // SwiftUI parity: ProgressView placeholder sits on the card's systemGray6.
        preview.backgroundColor = .systemGray6
        body.addArrangedSubview(preview)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        let ctaLabel = UILabel()
        ctaLabel.translatesAutoresizingMaskIntoConstraints = false
        ctaLabel.font = UIFont.preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
        ctaLabel.textColor = .systemBlue

        // SwiftUI parity: VStack(alignment: .leading, spacing: 8) padded by 10.
        let textStack = UIStackView(arrangedSubviews: [titleLabel, ctaLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8
        textStack.isLayoutMarginsRelativeArrangement = true
        textStack.directionalLayoutMargins = .init(top: 10, leading: 10, bottom: 10, trailing: 10)
        body.addArrangedSubview(textStack)

        let title = attachment.title ?? ""
        let cta = attachment.callToActionText ?? ""
        titleLabel.text = title
        ctaLabel.text = cta
        ctaLabel.isHidden = cta.isEmpty
        // SwiftUI parity: the text section renders only when a title is present.
        textStack.isHidden = title.isEmpty

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 220),
            preview.heightAnchor.constraint(equalToConstant: 140),

            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])

        preview.load(url: attachment.previewImageUrl ?? attachment.contentUrl,
                     fallback: Self.imageFallback)

        let openURL = attachment.contentUrl
        card.addAction(UIAction { _ in
            if let openURL { UIApplication.shared.open(openURL) }
        }, for: .touchUpInside)

        return card
    }

    /// SwiftUI parity: a 220×140 systemGray4 rectangle with a centered gray
    /// `photo` icon. Pre-rendered at the preview size so `scaleAspectFill`
    /// fits it exactly (no stretching of the bare SF Symbol).
    private static let imageFallback: UIImage = {
        let size = CGSize(width: 220, height: 140)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemGray4.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            if let symbol = UIImage(systemName: "photo", withConfiguration: config)?
                .withTintColor(.gray, renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2,
                                        y: (size.height - symbol.size.height) / 2))
            }
        }
    }()
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
