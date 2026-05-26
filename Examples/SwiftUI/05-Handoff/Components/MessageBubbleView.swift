// Copyright PolyAI Limited

//  MessageBubbleView.swift
//  Examples/SwiftUI/05-Handoff
//
//  Mirrors README:
//    - § "What you can build > Live agent handoff"
//    - § "What you can build > Rich attachments"
//    - § "What you can build > Delivery tracking"
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import SwiftUI
import PolyMessaging

/// Renders a single message. Live-agent bubbles get teal styling + the agent
/// name label above the bubble, so users can tell a human is on the other end.
struct MessageBubbleView: View {
    let message: ChatMessage
    var onRetry: ((String) -> Void)? = nil
    var showSendingLabel: Bool = false
    var showSuggestions: Bool = false
    var onSuggestionTap: ((String) -> Void)? = nil

    var body: some View {
        switch message {
        case .user(let m):
            userRow(m)
        case .agent(let m):
            agentRow(m)
        case .system(let m):
            systemRow(m)
        }
    }

    // MARK: - User

    private func userRow(_ m: UserMessage) -> some View {
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
    }

    // MARK: - Agent (poly OR live)

    private func agentRow(_ m: AgentMessage) -> some View {
        let isLive = (m.agentKind == .live)

        return HStack(alignment: .top, spacing: 8) {
            avatar(url: m.avatarUrl, isLive: isLive)

            VStack(alignment: .leading, spacing: 4) {
                if let name = m.agentName, !name.isEmpty {
                    Text(isLive ? "\(name) · live agent" : name)
                        .font(.caption2)
                        .foregroundColor(isLive ? .teal : .secondary)
                }

                if !m.text.isEmpty {
                    HStack {
                        RichText(m.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(isLive ? Color.teal.opacity(0.18) : Color(.systemGray5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(isLive ? Color.teal.opacity(0.5) : Color.clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        Spacer(minLength: 60)
                    }
                }

                if !m.attachments.isEmpty {
                    let urlCards = m.attachments.filter { $0.contentType == .url }
                    let images = m.attachments.filter { $0.contentType != .url }
                    if !images.isEmpty {
                        AttachmentCarousel(attachments: images)
                    }
                    ForEach(Array(urlCards.enumerated()), id: \.offset) { _, att in
                        URLCard(attachment: att)
                    }
                }

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
            }
        }
    }

    // MARK: - System

    private func systemRow(_ m: SystemMessage) -> some View {
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

    private func systemText(for event: SystemEvent) -> String {
        switch event {
        case .conversationEnded: return "This conversation has ended"
        case .agentLeft: return "Agent left"
        case .liveAgentJoined(let name): return "\(name ?? "An agent") joined"
        case .liveAgentLeft: return "Agent left"
        case .queueStatus(let position, let displayMessage):
            if let displayMessage, !displayMessage.isEmpty { return displayMessage }
            return position.map { "Position #\($0) in queue" } ?? "Queued..."
        case .handoffStarted: return "Transferring to a live agent..."
        case .handoffRequired(let reason): return reason.isEmpty ? "Switching support channel" : "Switching to \(reason)"
        case .handoffAccepted: return "An agent will be with you shortly"
        case .handoffFailed(let reason): return reason.map { "Transfer failed: \($0)" } ?? "Transfer failed"
        case .handoffTimeout: return "No agents available"
        case .idleWarning: return "Session will expire soon"
        case .serverMessage(let text, _): return text
        }
    }

    // MARK: - Bits

    @ViewBuilder
    private func avatar(url: URL?, isLive: Bool) -> some View {
        let size: CGFloat = 28
        if let url {
            RetryableAsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackIcon(isLive: isLive, size: size)
            } fallback: {
                fallbackIcon(isLive: isLive, size: size)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(isLive ? Color.teal : Color.clear, lineWidth: 1.5))
        } else {
            fallbackIcon(isLive: isLive, size: size)
                .overlay(Circle().stroke(isLive ? Color.teal : Color.clear, lineWidth: 1.5))
        }
    }

    private func fallbackIcon(isLive: Bool, size: CGFloat) -> some View {
        Image(systemName: isLive ? "person.fill" : "person.circle.fill")
            .resizable()
            .frame(width: size, height: size)
            .foregroundColor(isLive ? .teal : Color(.systemGray3))
    }
}
