// Copyright PolyAI Limited

//  MessageBubbleView.swift
//  Examples/SwiftUI/03-RichContent
//
//  Mirrors README:
//    - § "What you can build > Rich attachments"
//    - § "What you can build > Delivery tracking"
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

                    // 1. Rich text (basic markdown — bold, italic, links).
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

                    // 2. Image attachments → horizontal carousel.
                    let images = m.attachments.filter { $0.contentType == .image }
                    if !images.isEmpty {
                        AttachmentCarousel(attachments: images)
                    }

                    // 3. URL attachments → vertical stack of cards.
                    let urls = m.attachments.filter { $0.contentType == .url }
                    if !urls.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { _, att in
                                URLCard(attachment: att)
                            }
                        }
                    }

                    // 4. `.unknown` content types are intentionally dropped —
                    //    forward-compat for new attachment kinds the SDK may add.

                    // 5. Call-to-call actions → row of green tel: buttons.
                    if !m.callActions.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(m.callActions) { action in
                                CallActionButton(action: action)
                            }
                        }
                    }

                    // 6. Quick-reply suggestions, under the last agent message.
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
