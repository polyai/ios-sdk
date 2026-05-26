// Copyright PolyAI Limited

//  LoadingSkeleton.swift
// Examples/UIKit/04-Resilience
//
//  Mirrors the SwiftUI loading skeleton shape: three leading, pulsing
//  rounded rows that preview where the first agent messages will land.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

/// Decorative placeholder rows shown while the session is opening and no
/// messages have arrived yet.
final class LoadingSkeleton: UIView {

    private let stack = UIStackView()
    private let rows: [UIView]
    private var isAnimating = false

    override init(frame: CGRect) {
        let widths: [CGFloat] = [220, 260, 190]
        self.rows = widths.map { _ in UIView() }
        super.init(frame: frame)
        configure(widths: widths)
    }

    required init?(coder: NSCoder) {
        let widths: [CGFloat] = [220, 260, 190]
        self.rows = widths.map { _ in UIView() }
        super.init(coder: coder)
        configure(widths: widths)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 170)
    }

    private func configure(widths: [CGFloat]) {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .systemBackground
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        addSubview(stack)

        for (index, row) in rows.enumerated() {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.layer.cornerRadius = 16
            row.backgroundColor = .systemGray5
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: widths[index]),
                row.heightAnchor.constraint(equalToConstant: 42),
            ])
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopPulse()
        } else if !isHidden {
            startPulse()
        }
    }

    override var isHidden: Bool {
        didSet {
            isHidden ? stopPulse() : startPulse()
        }
    }

    private func startPulse() {
        guard !isAnimating, window != nil else { return }
        isAnimating = true
        rows.forEach { $0.alpha = 1 }
        UIView.animate(
            withDuration: 1.1,
            delay: 0,
            options: [.repeat, .autoreverse, .curveEaseInOut, .allowUserInteraction],
            animations: { [weak self] in
                self?.rows.forEach { $0.alpha = 0.43 }
            }
        )
    }

    private func stopPulse() {
        guard isAnimating else { return }
        isAnimating = false
        rows.forEach {
            $0.layer.removeAllAnimations()
            $0.alpha = 1
        }
    }
}
