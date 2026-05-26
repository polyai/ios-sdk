// Copyright PolyAI Limited

//  MessageBubbleView.swift
//  Examples/SwiftUI/02-Standard
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

struct MessageBubbleView: View {
    let message: ChatMessage
    var onRetry: ((String) -> Void)? = nil
    var showSendingLabel: Bool = false
    var showSuggestions: Bool = false
    var onSuggestionTap: ((String) -> Void)? = nil

    var body: some View {
        switch message {
        case .user(let m):
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 60)
                if m.delivery == .failed {
                    Button {
                        onRetry?(m.text)
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
                        // Cap bubble width at ~75% of the screen so very long
                        // messages wrap inside the bubble instead of pushing
                        // past the row's trailing edge into the nav bar.
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: .trailing)

                    if showSendingLabel && m.delivery == .pending {
                        Text("Sending...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if m.delivery == .failed {
                        Text("Tap to retry")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
            }

        case .agent(let m):
            HStack(alignment: .top, spacing: 8) {
                AgentAvatarView(url: m.avatarUrl)
                VStack(alignment: .leading, spacing: 4) {
                    if let name = m.agentName, !name.isEmpty {
                        Text(name)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(m.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.systemGray5))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        Spacer(minLength: 60)
                    }

                    if showSuggestions && !m.suggestions.isEmpty {
                        SuggestionRow(suggestions: m.suggestions.map { $0.messageText }) { s in
                            onSuggestionTap?(s)
                        }
                        .padding(.top, 4)
                    }
                }
            }

        case .system(let m):
            HStack {
                Spacer()
                Text(systemText(for: m.event))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                Spacer()
            }
        }
    }

    private func systemText(for event: SystemEvent) -> String {
        switch event {
        case .conversationEnded: return "Conversation ended"
        case .agentLeft: return "Agent left"
        case .liveAgentJoined(let name): return "\(name ?? "Agent") joined"
        case .liveAgentLeft: return "Live agent left"
        case .queueStatus(_, let msg): return msg ?? "Waiting in queue…"
        case .handoffStarted: return "Transferring you…"
        case .handoffRequired(let reason): return "Handoff: \(reason)"
        case .handoffAccepted: return "Connected to live agent"
        case .handoffFailed(let reason): return "Handoff failed: \(reason ?? "unknown")"
        case .handoffTimeout: return "Handoff timed out"
        case .idleWarning: return "Session will close due to inactivity"
        case .serverMessage(let text, _): return text
        }
    }
}

// MARK: - Agent Avatar

struct AgentAvatarView: View {
    let url: URL?
    private let size: CGFloat = 28

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    fallbackIcon
                }
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
