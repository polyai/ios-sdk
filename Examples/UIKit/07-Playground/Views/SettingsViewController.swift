//  SettingsViewController.swift
//  Examples/UIKit/07-Playground
//
//  Runtime Configuration controls + protocol simulations. The UIKit counterpart
//  of the SwiftUI 07 `SettingsSheet`: a scrollable form of grouped sections —
//  live diagnostics, raw frame sends, close-code simulations, display toggles,
//  environment / session / advanced knobs, and reset.
//  Edits write straight back to DevSettings (UserDefaults).
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit
import Combine
import PolyMessaging

final class SettingsViewController: UIViewController {

    // MARK: - Inputs

    private let settings: DevSettings
    private let diagnostics: DevDiagnostics
    private let hasLiveSession: Bool
    private let hasResumableSession: Bool

    var onApplyAndRestart: (() -> Void)?
    var onForceReconnect: (() -> Void)?
    var onSimulateDrop: (() -> Void)?
    var onDisconnectClean: (() -> Void)?
    var onSimulateServerReject: (() -> Void)?
    var onSimulateIdleTimeout: (() -> Void)?
    var onSendHeartbeat: (() -> Void)?
    var onSendTypingStart: (() -> Void)?
    var onSendTypingStop: (() -> Void)?
    var onSendUserEndSession: (() -> Void)?
    var onSendUserLeft: (() -> Void)?

    private var hasAnySession: Bool { hasLiveSession || hasResumableSession }

    // MARK: - State

    private let contentStack = UIStackView()
    private var diagnosticLabels: [String: UILabel] = [:]
    private var envMenuButton: UIButton!
    private var logLevelButton: UIButton!
    private var clusterRow: UIView!
    private var customURLRow: UIView!
    private var resolvedEnvLabel: UILabel!
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?

    init(settings: DevSettings, diagnostics: DevDiagnostics, hasLiveSession: Bool, hasResumableSession: Bool) {
        self.settings = settings
        self.diagnostics = diagnostics
        self.hasLiveSession = hasLiveSession
        self.hasResumableSession = hasResumableSession
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func doneTapped() { dismiss(animated: true) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "Dev Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 22
        scroll.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            contentStack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        buildSections()
        refreshDiagnostics()

        diagnostics.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.refreshDiagnostics() } }
            .store(in: &bag)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshDiagnostics()
        }
    }

    deinit { timer?.invalidate() }

    // MARK: - Section assembly

    private func buildSections() {
        if hasAnySession { contentStack.addArrangedSubview(mismatchBanner()) }
        contentStack.addArrangedSubview(diagnosticsSection())
        if hasLiveSession {
            contentStack.addArrangedSubview(sendFramesSection())
            contentStack.addArrangedSubview(disconnectSection())
        }
        contentStack.addArrangedSubview(displaySection())
        contentStack.addArrangedSubview(environmentSection())
        contentStack.addArrangedSubview(sessionSection())
        contentStack.addArrangedSubview(advancedSection())
        contentStack.addArrangedSubview(resetSection())
    }

    private func mismatchBanner() -> UIView {
        let card = cardContainer()
        let stack = cardStack(in: card)

        let title = UILabel()
        title.text = hasLiveSession ? "⚠︎ Live session active" : "⚠︎ Resumable session exists"
        title.font = .preferredFont(forTextStyle: .subheadline).bold()
        title.numberOfLines = 0

        let body = UILabel()
        body.text = hasLiveSession
            ? "Streaming, greeting and environment changes only apply to NEW sessions."
            : "A previous session is stored on disk. Session-creation settings here only apply once you start fresh."
        body.font = .preferredFont(forTextStyle: .caption1)
        body.textColor = .secondaryLabel
        body.numberOfLines = 0

        var conf = UIButton.Configuration.borderedProminent()
        conf.title = "Apply & Start New Session"
        conf.image = UIImage(systemName: "arrow.clockwise.circle.fill")
        conf.imagePadding = 6
        conf.baseBackgroundColor = .systemOrange
        let button = UIButton(configuration: conf, primaryAction: UIAction { [weak self] _ in
            self?.onApplyAndRestart?()
            self?.dismiss(animated: true)
        })

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(button)
        return card
    }

    private func diagnosticsSection() -> UIView {
        let (card, stack) = section(title: "DIAGNOSTICS", footer: "Live values from the SDK. Counters reset when a fresh client is created.")
        let rows = ["Status", "Session ID", "Ready", "Last sequence", "Frames in / out",
                    "Chunks received", "Heartbeats in", "Reconnects", "Last frame",
                    "Server streaming", "Max message size", "Server heartbeat", "Server max reconnect"]
        for r in rows {
            let (row, value) = labeledValueRow(r)
            diagnosticLabels[r] = value
            stack.addArrangedSubview(row)
        }
        return card
    }

    private func sendFramesSection() -> UIView {
        let (card, stack) = section(title: "SEND FRAMES", footer: "Wire-level events sent directly to the server via the raw connection.")
        stack.addArrangedSubview(actionRow("Send HEARTBEAT", icon: "waveform.path.ecg") { [weak self] in self?.fire("Heartbeat sent", self?.onSendHeartbeat) })
        stack.addArrangedSubview(actionRow("Send USER_TYPING (started)", icon: "ellipsis.bubble") { [weak self] in self?.fire("Typing started", self?.onSendTypingStart) })
        stack.addArrangedSubview(actionRow("Send USER_TYPING (stopped)", icon: "ellipsis.bubble.fill") { [weak self] in self?.fire("Typing stopped", self?.onSendTypingStop) })
        stack.addArrangedSubview(actionRow("Send USER_END_SESSION", icon: "xmark.circle", destructive: true) { [weak self] in self?.fire("End session sent", self?.onSendUserEndSession) })
        stack.addArrangedSubview(actionRow("Send USER_LEFT", icon: "rectangle.portrait.and.arrow.right", destructive: true) { [weak self] in self?.fire("User left sent", self?.onSendUserLeft) })
        return card
    }

    private func disconnectSection() -> UIView {
        let (card, stack) = section(title: "DISCONNECT / RECONNECT", footer: "Exercises each ConnectionService close-code path. 1006 reconnects, 4001 refetches, 1000 is terminal.")
        stack.addArrangedSubview(actionRow("Force reconnect (1006)", icon: "arrow.clockwise") { [weak self] in self?.fire("Reconnect triggered", self?.onForceReconnect) })
        stack.addArrangedSubview(actionRow("Simulate network drop (1006)", icon: "wifi.slash") { [weak self] in self?.fire("Simulated network drop", self?.onSimulateDrop) })
        stack.addArrangedSubview(actionRow("Simulate idle timeout (4002)", icon: "clock.badge.exclamationmark") { [weak self] in self?.fire("Idle-timeout close sent", self?.onSimulateIdleTimeout) })
        stack.addArrangedSubview(actionRow("Simulate server reject (4001)", icon: "exclamationmark.shield", destructive: true) { [weak self] in self?.fire("Server-reject close sent", self?.onSimulateServerReject) })
        stack.addArrangedSubview(actionRow("Clean disconnect (1000)", icon: "xmark.octagon.fill", destructive: true) { [weak self] in self?.fire("Clean disconnect sent", self?.onDisconnectClean) })
        return card
    }

    private func displaySection() -> UIView {
        let (card, stack) = section(title: "DISPLAY", footer: "Visual debug aids inside the chat screen.")
        stack.addArrangedSubview(toggleRow("Show debug strip in chat", value: settings.showDebugStrip) { [weak self] on in self?.settings.showDebugStrip = on })
        stack.addArrangedSubview(toggleRow("Message timestamps", value: settings.showMessageTimestamps) { [weak self] on in self?.settings.showMessageTimestamps = on })
        return card
    }

    private func environmentSection() -> UIView {
        let (card, stack) = section(title: "ENVIRONMENT", footer: "Switches the REST + WebSocket base URLs. Applies on next session creation.")

        envMenuButton = menuButton(title: settings.environmentKind.displayName)
        envMenuButton.menu = environmentMenu()
        stack.addArrangedSubview(fieldRow("Target", control: envMenuButton))

        clusterRow = textFieldRow("Cluster name", placeholder: "us-1", value: settings.clusterName) { [weak self] t in
            self?.settings.clusterName = t
            self?.refreshResolvedEnv()
        }
        stack.addArrangedSubview(clusterRow)

        customURLRow = customURLSubsection()
        stack.addArrangedSubview(customURLRow)

        let (resolvedRow, resolvedValue) = labeledValueRow("Resolved")
        resolvedEnvLabel = resolvedValue
        stack.addArrangedSubview(resolvedRow)

        updateEnvironmentVisibility()
        refreshResolvedEnv()
        return card
    }

    private func sessionSection() -> UIView {
        let (card, stack) = section(title: "SESSION", footer: "Sent in the /sessions request body.")
        stack.addArrangedSubview(toggleRow("Streaming enabled", value: settings.streamingEnabled) { [weak self] on in self?.settings.streamingEnabled = on })
        stack.addArrangedSubview(textFieldRow("Greeting message", placeholder: "(server default)", value: settings.greetingMessage) { [weak self] t in self?.settings.greetingMessage = t })

        logLevelButton = menuButton(title: logLevelName(settings.logLevel))
        logLevelButton.menu = logLevelMenu()
        stack.addArrangedSubview(fieldRow("Log level", control: logLevelButton))
        return card
    }

    private func advancedSection() -> UIView {
        let (card, stack) = section(title: "ADVANCED", footer: "0 = use SDK default. Server SessionCapabilities still wins after SESSION_START.")
        stack.addArrangedSubview(stepperRow("Heartbeat", value: settings.heartbeatIntervalSeconds, range: 0...300, step: 5,
                                            format: { self.secondsLabel($0, def: "30s") }) { [weak self] v in self?.settings.heartbeatIntervalSeconds = v })
        stack.addArrangedSubview(stepperRow("Session timeout", value: settings.sessionTimeoutSeconds, range: 0...86400, step: 60,
                                            format: { self.secondsLabel($0, def: "10m") }) { [weak self] v in self?.settings.sessionTimeoutSeconds = v })
        stack.addArrangedSubview(stepperRow("Max reconnects", value: settings.maxReconnectAttempts, range: 0...50, step: 1,
                                            format: { $0 == 0 ? "10 (default)" : "\($0)" }) { [weak self] v in self?.settings.maxReconnectAttempts = v })
        return card
    }

    private func resetSection() -> UIView {
        let (card, stack) = section(title: nil, footer: nil)
        var conf = UIButton.Configuration.gray()
        conf.title = "Reset to defaults"
        conf.image = UIImage(systemName: "arrow.counterclockwise")
        conf.imagePadding = 6
        conf.baseForegroundColor = .systemRed
        let button = UIButton(configuration: conf, primaryAction: UIAction { [weak self] _ in
            self?.settings.resetToDefaults()
            self?.reloadAfterReset()
        })
        button.contentHorizontalAlignment = .leading
        stack.addArrangedSubview(button)
        return card
    }

    // MARK: - Environment helpers

    private func environmentMenu() -> UIMenu {
        let actions = DevSettings.EnvironmentKind.allCases.map { kind in
            UIAction(title: kind.displayName, state: settings.environmentKind == kind ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.settings.environmentKind = kind
                self.envMenuButton.setTitle(kind.displayName, for: .normal)
                self.envMenuButton.menu = self.environmentMenu()
                self.updateEnvironmentVisibility()
                self.refreshResolvedEnv()
            }
        }
        return UIMenu(children: actions)
    }

    private func customURLSubsection() -> UIView {
        let restRow = textFieldRow("REST base URL", placeholder: "https://...", value: settings.customRestURL) { [weak self] t in
            self?.settings.customRestURL = t
            self?.refreshResolvedEnv()
        }
        let wsRow = textFieldRow("WS base URL", placeholder: "wss://.../ws", value: settings.customWsURL) { [weak self] t in
            self?.settings.customWsURL = t
        }
        let stack = UIStackView(arrangedSubviews: [restRow, wsRow])
        stack.axis = .vertical
        stack.spacing = 10
        return stack
    }

    private func updateEnvironmentVisibility() {
        clusterRow.isHidden = settings.environmentKind != .cluster
        customURLRow.isHidden = settings.environmentKind != .custom
    }

    private func refreshResolvedEnv() {
        resolvedEnvLabel?.text = settings.environmentDisplayName()
    }

    private func logLevelMenu() -> UIMenu {
        let levels: [LogLevel] = [.none, .error, .warn, .info, .debug]
        let actions = levels.map { level in
            UIAction(title: logLevelName(level), state: settings.logLevel == level ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.settings.logLevel = level
                self.logLevelButton.setTitle(self.logLevelName(level), for: .normal)
                self.logLevelButton.menu = self.logLevelMenu()
            }
        }
        return UIMenu(children: actions)
    }

    private func logLevelName(_ level: LogLevel) -> String {
        switch level {
        case .none: return "None"
        case .error: return "Error"
        case .warn: return "Warn"
        case .info: return "Info"
        case .debug: return "Debug"
        }
    }

    private func reloadAfterReset() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        diagnosticLabels.removeAll()
        buildSections()
        refreshDiagnostics()
    }

    // MARK: - Diagnostics refresh

    private func refreshDiagnostics() {
        func set(_ key: String, _ value: String) { diagnosticLabels[key]?.text = value }
        set("Status", diagnostics.connectionLabel)
        set("Session ID", shortened(diagnostics.sessionId))
        set("Ready", diagnostics.isReady ? "yes" : "no")
        set("Last sequence", "\(diagnostics.lastSequence)")
        set("Frames in / out", "\(diagnostics.framesIn) / \(diagnostics.framesOut)")
        set("Chunks received", "\(diagnostics.chunksIn)")
        set("Heartbeats in", "\(diagnostics.heartbeatsIn)")
        set("Reconnects", "\(diagnostics.reconnectCount)")
        set("Last frame", lastFrameLabel())
        set("Server streaming", diagnostics.streamingCapability.map { $0 ? "yes" : "no" } ?? "—")
        set("Max message size", diagnostics.maxMessageSize.map { $0 == 0 ? "unlimited" : "\($0) bytes" } ?? "—")
        set("Server heartbeat", diagnostics.serverHeartbeatSeconds.map { $0 == 0 ? "disabled" : "\($0)s" } ?? "—")
        set("Server max reconnect", diagnostics.serverMaxReconnectAttempts.map { $0 == 0 ? "unlimited" : "\($0)" } ?? "—")
    }

    private func lastFrameLabel() -> String {
        guard let at = diagnostics.lastInboundAt else { return "—" }
        let s = Int(Date().timeIntervalSince(at))
        if s < 1 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        return "\(s / 60)m ago"
    }

    private func shortened(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        if s.count <= 12 { return s }
        return s.prefix(4) + "…" + s.suffix(8)
    }

    private func secondsLabel(_ secs: Int, def: String) -> String {
        if secs == 0 { return def + " (default)" }
        if secs >= 3600 { return "\(secs / 3600)h" + (secs % 3600 == 0 ? "" : " \(secs % 3600 / 60)m") }
        if secs >= 60 { return "\(secs / 60)m" + (secs % 60 == 0 ? "" : " \(secs % 60)s") }
        return "\(secs)s"
    }

    private func fire(_ message: String, _ action: (() -> Void)?) {
        guard let action else { return }
        action()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        toast(message)
    }

    private func toast(_ text: String) {
        let label = PaddingLabel()
        label.text = text
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .callout)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.layer.cornerRadius = 16
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        label.alpha = 0
        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 1.3, options: []) { label.alpha = 0 } completion: { _ in
                label.removeFromSuperview()
            }
        }
    }

    // MARK: - Row builders

    private func cardContainer() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func cardStack(in card: UIView) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return stack
    }

    /// Returns an outer container (title + card + footer) and the inner row stack to fill.
    private func section(title: String?, footer: String?) -> (UIView, UIStackView) {
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 6

        if let title {
            let header = UILabel()
            header.text = title
            header.font = .preferredFont(forTextStyle: .footnote)
            header.textColor = .secondaryLabel
            outer.addArrangedSubview(header)
        }

        let card = cardContainer()
        let stack = cardStack(in: card)
        outer.addArrangedSubview(card)

        if let footer {
            let f = UILabel()
            f.text = footer
            f.font = .preferredFont(forTextStyle: .caption2)
            f.textColor = .secondaryLabel
            f.numberOfLines = 0
            outer.addArrangedSubview(f)
        }
        return (outer, stack)
    }

    private func labeledValueRow(_ label: String) -> (UIView, UILabel) {
        let name = UILabel()
        name.text = label
        name.font = .preferredFont(forTextStyle: .body)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let value = UILabel()
        value.font = .preferredFont(forTextStyle: .body)
        value.textColor = .secondaryLabel
        value.textAlignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [name, value])
        row.axis = .horizontal
        row.spacing = 8
        return (row, value)
    }

    private func fieldRow(_ label: String, control: UIView) -> UIView {
        let name = UILabel()
        name.text = label
        name.font = .preferredFont(forTextStyle: .body)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [name, control])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func toggleRow(_ label: String, value: Bool, onChange: @escaping (Bool) -> Void) -> UIView {
        let toggle = UISwitch()
        toggle.isOn = value
        toggle.addAction(UIAction { _ in onChange(toggle.isOn) }, for: .valueChanged)
        return fieldRow(label, control: toggle)
    }

    private func textFieldRow(_ label: String, placeholder: String, value: String, onChange: @escaping (String) -> Void) -> UIView {
        let name = UILabel()
        name.text = label
        name.font = .preferredFont(forTextStyle: .caption1)
        name.textColor = .secondaryLabel

        let field = UITextField()
        field.placeholder = placeholder
        field.text = value
        field.font = .preferredFont(forTextStyle: .body)
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.addAction(UIAction { _ in onChange(field.text ?? "") }, for: .editingChanged)

        let stack = UIStackView(arrangedSubviews: [name, field])
        stack.axis = .vertical
        stack.spacing = 4
        return stack
    }

    private func stepperRow(_ label: String, value: Int, range: ClosedRange<Int>, step: Int,
                            format: @escaping (Int) -> String, onChange: @escaping (Int) -> Void) -> UIView {
        let name = UILabel()
        name.text = label
        name.font = .preferredFont(forTextStyle: .body)

        let valueLabel = UILabel()
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.text = format(value)

        let stepper = UIStepper()
        stepper.minimumValue = Double(range.lowerBound)
        stepper.maximumValue = Double(range.upperBound)
        stepper.stepValue = Double(step)
        stepper.value = Double(value)
        stepper.addAction(UIAction { _ in
            let v = Int(stepper.value)
            valueLabel.text = format(v)
            onChange(v)
        }, for: .valueChanged)

        let textStack = UIStackView(arrangedSubviews: [name, valueLabel])
        textStack.axis = .horizontal
        textStack.spacing = 8

        let row = UIStackView(arrangedSubviews: [textStack, stepper])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    private func actionRow(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> UIView {
        var conf = UIButton.Configuration.plain()
        conf.title = title
        conf.image = UIImage(systemName: icon)
        conf.imagePadding = 10
        conf.contentInsets = .zero
        conf.baseForegroundColor = destructive ? .systemRed : .label
        let button = UIButton(configuration: conf, primaryAction: UIAction { _ in action() })
        button.contentHorizontalAlignment = .leading
        button.isEnabled = hasLiveSession
        return button
    }

    private func menuButton(title: String) -> UIButton {
        var conf = UIButton.Configuration.gray()
        conf.title = title
        conf.image = UIImage(systemName: "chevron.up.chevron.down")
        conf.imagePlacement = .trailing
        conf.imagePadding = 6
        conf.cornerStyle = .medium
        let button = UIButton(configuration: conf)
        button.showsMenuAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}

// MARK: - Helpers

private final class PaddingLabel: UILabel {
    private let inset = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right, height: s.height + inset.top + inset.bottom)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
}
