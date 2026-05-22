import SwiftUI

struct LogsSheet: View {
    let logs: [LogEntry]
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var filteredLogs: [LogEntry] {
        if filter.isEmpty { return logs }
        return logs.filter {
            $0.summary.localizedCaseInsensitiveContains(filter)
            || ($0.detail?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Label("\(logs.count)", systemImage: "text.line.last.and.arrowtriangle.forward")
                    if !filter.isEmpty {
                        Label("\(filteredLogs.count) match", systemImage: "line.3.horizontal.decrease")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))

                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Filter logs...", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.vertical, 6)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(filteredLogs.enumerated()), id: \.element.id) { i, entry in
                                LogEntryView(entry: entry, index: i).id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        if let last = filteredLogs.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string = logs
                            .map { $0.summary + ($0.detail.map { "\n\($0)" } ?? "") }
                            .joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct LogEntryView: View {
    let entry: LogEntry
    let index: Int
    @State private var isExpanded = false

    private var logLevel: LogLevel {
        let lower = entry.summary.lowercased()
        if lower.contains("error") || lower.contains("failed") { return .error }
        if lower.contains("warn") || lower.contains("timeout") { return .warning }
        if lower.contains("connected") || lower.contains("session started") || lower.contains("confirmed") { return .success }
        if lower.contains("chunk") || lower.contains("thinking") { return .verbose }
        return .info
    }

    enum LogLevel {
        case error, warning, success, info, verbose

        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .success: return .green
            case .info: return .primary
            case .verbose: return .secondary
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: logLevel.icon)
                    .font(.system(size: 12))
                    .foregroundColor(logLevel.color)
                    .frame(width: 16)

                Text(entry.summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(isExpanded ? nil : 1)

                Spacer(minLength: 4)

                if entry.detail != nil {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                if entry.detail != nil {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
            }

            if isExpanded, let detail = entry.detail {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detail.components(separatedBy: "\n"), id: \.self) { line in
                        if let colonIdx = line.firstIndex(of: ":") {
                            HStack(alignment: .top, spacing: 4) {
                                Text(String(line[line.startIndex...colonIdx]))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.blue)
                                Text(String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                        } else {
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(index % 2 == 0 ? Color(.systemBackground) : Color(.secondarySystemBackground))
    }
}
