// Copyright PolyAI Limited

//  LogsViewController.swift
//  Examples/UIKit/07-Playground
//
//  Human-readable raw event log. Mirrors the SwiftUI 07 `LogsSheet`: a count
//  header, a filter field, monospaced rows that expand to show detail, a copy
//  button, and Done. Presented as a sheet by RootViewController.
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

final class LogsViewController: UIViewController {

    private let logs: [LogEntry]
    private var filtered: [LogEntry]
    private var expanded = Set<UUID>()
    private var filter = ""

    private let countLabel = UILabel()
    private let filterField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(logs: [LogEntry]) {
        self.logs = logs
        self.filtered = logs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func doneTapped() { dismiss(animated: true) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Debug Logs"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in self?.copyAll() }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )

        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabel
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let filterBg = UIView()
        filterBg.backgroundColor = .systemGray6
        filterBg.layer.cornerRadius = 8
        filterBg.translatesAutoresizingMaskIntoConstraints = false

        let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        magnifier.tintColor = .secondaryLabel
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholder = "Filter logs..."
        filterField.font = .preferredFont(forTextStyle: .caption1)
        filterField.borderStyle = .none
        filterField.autocapitalizationType = .none
        filterField.autocorrectionType = .no
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.addAction(UIAction { [weak self] _ in
            self?.filter = self?.filterField.text ?? ""
            self?.applyFilter()
        }, for: .editingChanged)

        filterBg.addSubview(magnifier)
        filterBg.addSubview(filterField)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.register(LogCell.self, forCellReuseIdentifier: LogCell.reuseID)

        view.addSubview(countLabel)
        view.addSubview(filterBg)
        view.addSubview(tableView)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            filterBg.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 8),
            filterBg.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            filterBg.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            filterBg.heightAnchor.constraint(equalToConstant: 36),

            magnifier.leadingAnchor.constraint(equalTo: filterBg.leadingAnchor, constant: 10),
            magnifier.centerYAnchor.constraint(equalTo: filterBg.centerYAnchor),
            filterField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 8),
            filterField.trailingAnchor.constraint(equalTo: filterBg.trailingAnchor, constant: -10),
            filterField.centerYAnchor.constraint(equalTo: filterBg.centerYAnchor),

            tableView.topAnchor.constraint(equalTo: filterBg.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateCount()
        scrollToBottom()
    }

    private func applyFilter() {
        if filter.isEmpty {
            filtered = logs
        } else {
            filtered = logs.filter {
                $0.summary.localizedCaseInsensitiveContains(filter)
                || ($0.detail?.localizedCaseInsensitiveContains(filter) ?? false)
            }
        }
        updateCount()
        tableView.reloadData()
    }

    private func updateCount() {
        if filter.isEmpty {
            countLabel.text = "\(logs.count) entries"
        } else {
            countLabel.text = "\(logs.count) entries · \(filtered.count) match"
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = logs
            .map { $0.summary + ($0.detail.map { "\n\($0)" } ?? "") }
            .joined(separator: "\n")
    }

    private func scrollToBottom() {
        guard !filtered.isEmpty else { return }
        DispatchQueue.main.async {
            let idx = IndexPath(row: self.filtered.count - 1, section: 0)
            self.tableView.scrollToRow(at: idx, at: .bottom, animated: false)
        }
    }
}

extension LogsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LogCell.reuseID, for: indexPath) as! LogCell
        let entry = filtered[indexPath.row]
        cell.configure(entry: entry, expanded: expanded.contains(entry.id), zebra: indexPath.row % 2 == 0)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let entry = filtered[indexPath.row]
        guard entry.detail != nil else { return }
        if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

// MARK: - LogCell

private final class LogCell: UITableViewCell {
    static let reuseID = "LogCell"

    private let icon = UIImageView()
    private let summaryLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        contentView.addSubview(icon)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summaryLabel.numberOfLines = 0
        contentView.addSubview(summaryLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .systemBlue
        chevron.contentMode = .scaleAspectFit
        contentView.addSubview(chevron)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        contentView.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            summaryLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            summaryLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),

            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 4),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: LogEntry, expanded: Bool, zebra: Bool) {
        let level = Self.level(for: entry.summary)
        icon.image = UIImage(systemName: level.icon)
        icon.tintColor = level.color
        summaryLabel.text = entry.summary
        summaryLabel.numberOfLines = expanded ? 0 : 1
        backgroundColor = zebra ? .systemBackground : .secondarySystemBackground

        if let detail = entry.detail {
            chevron.isHidden = false
            chevron.image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down")
            detailLabel.isHidden = !expanded
            detailLabel.text = expanded ? detail : nil
        } else {
            chevron.isHidden = true
            detailLabel.isHidden = true
            detailLabel.text = nil
        }
    }

    private enum Level {
        case error, warning, success, info, verbose
        var color: UIColor {
            switch self {
            case .error: return .systemRed
            case .warning: return .systemOrange
            case .success: return .systemGreen
            case .info: return .label
            case .verbose: return .secondaryLabel
            }
        }
        var icon: String {
            switch self {
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle"
            case .verbose: return "ellipsis.circle"
            }
        }
    }

    private static func level(for summary: String) -> Level {
        let lower = summary.lowercased()
        if lower.contains("error") || lower.contains("failed") { return .error }
        if lower.contains("warn") || lower.contains("timeout") { return .warning }
        if lower.contains("connected") || lower.contains("session started") || lower.contains("confirmed") { return .success }
        if lower.contains("chunk") || lower.contains("thinking") { return .verbose }
        return .info
    }
}
