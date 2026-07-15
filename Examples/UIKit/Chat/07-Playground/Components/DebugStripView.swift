// Copyright PolyAI Limited

//  DebugStripView.swift
//  Examples/UIKit/07-Playground
//
//  Always-on, one-line observability strip rendered at the top of the chat
//  view when `DevSettings.showDebugStrip` is enabled. Mirrors the SwiftUI 07
//  `DebugStrip`: status / sequence / frame counts / chunks / last-frame age in
//  a black monospaced bar. Updates off DevDiagnostics + a 1s timer.
//

import UIKit
import Combine

final class DebugStripView: UIView {

    private let diagnostics: DevDiagnostics
    private let statusChip = ChipLabel()
    private let seqChip = ChipLabel()
    private let framesChip = ChipLabel()
    private let chunksChip = ChipLabel()
    private let ageChip = ChipLabel()
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?

    init(diagnostics: DevDiagnostics) {
        self.diagnostics = diagnostics
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.black.withAlphaComponent(0.78)

        let stack = UIStackView(arrangedSubviews: [statusChip, seqChip, framesChip, chunksChip, UIView(), ageChip])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        diagnostics.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &bag)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    private func refresh() {
        let label = diagnostics.connectionLabel
        statusChip.set(icon: statusIcon(label), text: label, color: statusColor(label))
        seqChip.set(icon: "number", text: "seq \(diagnostics.lastSequence)", color: .white.withAlphaComponent(0.85))
        framesChip.set(icon: "arrow.up.arrow.down",
                       text: "\(diagnostics.framesOut)→ ←\(diagnostics.framesIn)",
                       color: .white.withAlphaComponent(0.85))
        if diagnostics.chunksIn > 0 {
            chunksChip.isHidden = false
            chunksChip.set(icon: "waveform", text: "\(diagnostics.chunksIn)c", color: .systemBlue)
        } else {
            chunksChip.isHidden = true
        }
        ageChip.set(icon: "clock", text: lastFrameLabel(), color: .white.withAlphaComponent(0.85))
    }

    private func lastFrameLabel() -> String {
        guard let at = diagnostics.lastInboundAt else { return "—" }
        let s = Int(Date().timeIntervalSince(at))
        return s < 1 ? "0s" : "\(s)s"
    }

    private func statusIcon(_ label: String) -> String {
        switch label {
        case "open": return "dot.radiowaves.left.and.right"
        case "connecting": return "ellipsis"
        case let s where s.hasPrefix("reconnecting"): return "arrow.clockwise"
        case "closing", "closed": return "xmark.circle"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private func statusColor(_ label: String) -> UIColor {
        if label == "open" { return .systemGreen }
        if label == "connecting" || label.hasPrefix("reconnecting") { return .systemYellow }
        if label == "failed" || label == "closed" || label == "closing" { return .systemRed }
        return .white.withAlphaComponent(0.6)
    }

    // MARK: - ChipLabel

    private final class ChipLabel: UIView {
        private let icon = UIImageView()
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentMode = .scaleAspectFit
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            addSubview(icon)
            addSubview(label)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 11),
                icon.heightAnchor.constraint(equalToConstant: 11),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        func set(icon name: String, text: String, color: UIColor) {
            icon.image = UIImage(systemName: name)
            icon.tintColor = color
            label.text = text
            label.textColor = color
        }
    }
}
