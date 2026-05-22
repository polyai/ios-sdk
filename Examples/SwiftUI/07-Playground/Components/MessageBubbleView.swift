import SwiftUI
import PolyMessaging

struct MessageBubbleView: View {
    let message: ChatMessage
    var showSendingLabel: Bool = false
    var showSuggestions: Bool = false
    var showTimestamp: Bool = false
    var onSuggestionTap: ((String) -> Void)?
    var onRetry: ((String, String?) -> Void)?

    var body: some View {
        HStack {
            switch message {
            case .user(let m):
                Spacer(minLength: 60)
                HStack(alignment: .bottom, spacing: 6) {
                    if m.delivery == .failed {
                        Button {
                            onRetry?(m.text, m.draftId)
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.title3)
                        }
                        .accessibilityLabel("Retry sending message")
                    }

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(m.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(m.delivery == .failed ? Color.red.opacity(0.15) : Color.blue)
                            .foregroundColor(m.delivery == .failed ? .primary : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 18))

                        if showSendingLabel && m.delivery == .pending {
                            Text("Sending...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else if m.delivery == .failed {
                            Text("Tap to retry")
                                .font(.caption2)
                                .foregroundColor(.red)
                        } else if showTimestamp {
                            Text(MessageTimestamp.compactTime(m.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(userAccessibilityLabel(m))

            case .agent(let m):
                HStack(alignment: .top, spacing: 8) {
                    AgentAvatarView(url: m.avatarUrl)

                    VStack(alignment: .leading, spacing: 4) {
                        // Static, readable content — combined into ONE VoiceOver
                        // element so the message reads as a unit.
                        VStack(alignment: .leading, spacing: 4) {
                            if let name = m.agentName {
                                Text(name)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if !m.text.isEmpty {
                                HStack {
                                    RichText(m.text)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color(.systemGray5))
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                    Spacer(minLength: 60)
                                }
                            }

                            if !m.attachments.isEmpty {
                                AttachmentCarousel(attachments: m.attachments)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(agentAccessibilityLabel(m))

                        // Interactive controls must stay individually
                        // addressable (VoiceOver focus + tap, and UI tests).
                        if !m.callActions.isEmpty {
                            VStack(spacing: 6) {
                                ForEach(m.callActions) { action in
                                    CallActionButton(action: action)
                                }
                            }
                        }

                        if showSuggestions && !m.suggestions.isEmpty {
                            SuggestionRow(suggestions: m.suggestions.map { $0.messageText }) { s in
                                onSuggestionTap?(s)
                            }
                            .padding(.top, 4)
                        }

                        if showTimestamp && !m.text.isEmpty {
                            Text(MessageTimestamp.compactTime(m.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

            case .system(let m):
                Spacer()
                SystemPillView(event: m.event)
                Spacer()
            }
        }
        .padding(.horizontal)
    }

    private func userAccessibilityLabel(_ m: UserMessage) -> String {
        var label = "You said: \(m.text)"
        switch m.delivery {
        case .pending: label += ". Sending."
        case .failed: label += ". Failed to send."
        case .sent: break
        }
        return label
    }

    private func agentAccessibilityLabel(_ m: AgentMessage) -> String {
        let speaker = m.agentName ?? (m.agentKind == .live ? "Live agent" : "Agent")
        var parts: [String] = ["\(speaker) says: \(m.text)"]
        if !m.attachments.isEmpty {
            parts.append("\(m.attachments.count) attachment\(m.attachments.count == 1 ? "" : "s")")
        }
        if !m.suggestions.isEmpty {
            parts.append("\(m.suggestions.count) suggested repl\(m.suggestions.count == 1 ? "y" : "ies") available")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Agent Avatar

struct AgentAvatarView: View {
    let url: URL?
    private let size: CGFloat = 28

    var body: some View {
        if let url {
            RetryableAsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackIcon
            } fallback: {
                fallbackIcon
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .frame(width: size, height: size)
            .foregroundColor(Color(.systemGray3))
    }
}

// MARK: - System Pill

private struct SystemPillView: View {
    let event: SystemEvent

    var body: some View {
        switch event {
        case .handoffRequired(let route):
            handoffRequiredView(route: route)
        default:
            pillLabel(text: event.displayText, style: event.levelStyle)
        }
    }

    private func pillLabel(text: String, style: LevelStyle) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(style.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(style.background)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func handoffRequiredView(route: String) -> some View {
        if let url = URL(string: route), url.scheme?.hasPrefix("http") == true {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label(route, systemImage: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Open handoff link")
        } else {
            VStack(spacing: 4) {
                Text("Contact Support")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                if !route.isEmpty {
                    Text(route)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
        }
    }
}

private struct LevelStyle {
    let foreground: Color
    let background: Color

    static let info = LevelStyle(foreground: .secondary, background: Color(.systemGray6))
    static let warning = LevelStyle(foreground: .orange, background: Color.orange.opacity(0.12))
    static let error = LevelStyle(foreground: .red, background: Color.red.opacity(0.12))
}

extension SystemEvent {
    var displayText: String {
        switch self {
        case .conversationEnded:
            return "This conversation has ended"
        case .agentLeft, .liveAgentLeft:
            return ""
        case .liveAgentJoined(let name):
            return "Connected with \(name ?? "an agent")"
        case .queueStatus(let position, let displayMessage):
            return displayMessage ?? "Queue position: \(position ?? 0)"
        case .handoffStarted:
            return "Transferring you to an agent..."
        case .handoffRequired(let reason):
            return "Transfer required: \(reason)"
        case .handoffAccepted:
            return "An agent will be with you shortly"
        case .handoffFailed(let reason):
            return "Transfer failed: \(reason ?? "unknown")"
        case .handoffTimeout:
            return "Transfer timed out"
        case .idleWarning:
            return "Session will expire soon"
        case .serverMessage(let text, _):
            return text
        }
    }

    fileprivate var levelStyle: LevelStyle {
        switch self {
        case .serverMessage(_, let level):
            switch level {
            case .info: return .info
            case .warning: return .warning
            case .error: return .error
            }
        case .handoffFailed, .handoffTimeout:
            return .error
        case .idleWarning:
            return .warning
        default:
            return .info
        }
    }
}
