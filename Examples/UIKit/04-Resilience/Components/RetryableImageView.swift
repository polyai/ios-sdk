//  RetryableImageView.swift
// Examples/UIKit/04-Resilience
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

/// UIImageView that loads from a URL via URLSession + a transient cache,
/// with tap-to-retry on failure and a one-shot auto-retry after 5s.
final class RetryableImageView: UIImageView {

    private static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 128
        return c
    }()

    private var currentURL: URL?
    private var task: URLSessionDataTask?
    private var didAutoRetry = false
    private var fallbackImage: UIImage?
    private let activity = UIActivityIndicatorView(style: .medium)

    convenience init() { self.init(frame: .zero) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isUserInteractionEnabled = true
        backgroundColor = .secondarySystemBackground

        activity.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activity)
        NSLayoutConstraint.activate([
            activity.centerXAnchor.constraint(equalTo: centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(url: URL?, fallback: UIImage? = nil) {
        task?.cancel()
        image = nil
        didAutoRetry = false
        fallbackImage = fallback
        currentURL = url
        guard let url else {
            image = fallback
            return
        }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        activity.startAnimating()
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.activity.stopAnimating()
                guard self.currentURL == url else { return }
                if let data, let img = UIImage(data: data) {
                    Self.cache.setObject(img, forKey: url as NSURL)
                    self.image = img
                } else {
                    self.image = self.fallbackImage
                    self.scheduleAutoRetry(for: url)
                }
            }
        }
        task?.resume()
    }

    @objc private func tapped() {
        guard image == nil || image == fallbackImage, let url = currentURL else { return }
        load(url: url, fallback: fallbackImage)
    }

    private func scheduleAutoRetry(for url: URL) {
        guard !didAutoRetry else { return }
        didAutoRetry = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.currentURL == url else { return }
            self.load(url: url, fallback: self.fallbackImage)
        }
    }
}
