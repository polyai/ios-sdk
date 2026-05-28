// Copyright PolyAI Limited

import Foundation

public extension MessagingEvent {

    var debugSummary: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected(let err): return "Disconnected: \(err?.localizedDescription ?? "clean")"
        case .reconnecting(let n): return "Reconnecting (attempt \(n))"
        case .sessionStart: return "Session started"
        case .sessionEnd: return "Session ended"
        case .sessionIdleWarning: return "Session idle warning"
        case .userMessage(_, let m): return "User: \(m.text.prefix(40))"
        case .userTyping: return "User typing"
        case .userEndSession: return "User ended session"
        case .requestPolyAgentJoin: return "Request agent join"
        case .messagePending(let id, _): return "Message pending [\(id.prefix(8))]"
        case .messageConfirmed(let id, _): return "Message confirmed [\(id.prefix(8))]"
        case .messageFailed(let id): return "Message failed [\(id.prefix(8))]"
        case .agentThinking: return "Agent thinking"
        case .agentMessage(_, let m): return "Agent: \(m.text.prefix(40))"
        case .agentMessageChunk(_, let c): return "Chunk [\(c.messageId.prefix(8))]"
        case .agentJoined(_, let a): return "Agent joined: \(a.agentName ?? "")"
        case .agentLeft: return "Agent left"
        case .agentTriggeredHandoff: return "Agent triggered handoff"
        case .liveAgentJoined(_, let a): return "Live agent joined: \(a.agentName ?? "")"
        case .liveAgentTyping: return "Live agent typing"
        case .liveAgentMessage(_, let m): return "Live agent: \(m.text.prefix(40))"
        case .liveAgentLeft: return "Live agent left"
        case .systemMessage(_, let s): return "System: \(s.message.prefix(40))"
        case .heartbeat: return "Heartbeat"
        case .clientHandoffRequired(_, let p): return "Handoff required: \(p.reason)"
        case .handoffQueueStatus(_, let q): return "Queue position: \(q.position ?? 0)"
        case .handoffAccepted: return "Handoff accepted"
        case .handoffFailed(_, let p): return "Handoff failed: \(p.reason ?? "unknown")"
        case .handoffTimeout: return "Handoff timeout"
        }
    }

    var debugDetail: String {
        var lines: [String] = []
        if let env = envelope {
            if !env.id.isEmpty { lines.append("id: \(env.id)") }
            if let seq = env.sequence { lines.append("sequence: \(seq)") }
            lines.append("timestamp: \(formatDate(env.timestamp))")
            if let meta = env.metadata?.custom, !meta.isEmpty {
                for (k, v) in meta { lines.append("meta.\(k): \(v)") }
            }
        }
        switch self {
        case .sessionStart(_, let p):
            lines.append("streaming: \(p.capabilities.streaming)")
            lines.append("maxMessageSize: \(p.capabilities.maxMessageSize)")
            if let hb = p.capabilities.heartbeatIntervalSeconds { lines.append("heartbeatInterval: \(hb)s") }
            if let mr = p.capabilities.maxReconnectAttempts { lines.append("maxReconnects: \(mr)") }
        case .sessionEnd(_, let p):
            lines.append("reason: \(p.reason ?? "none")")
        case .agentMessage(_, let p):
            lines.append("messageId: \(p.messageId)")
            lines.append("text: \(p.text.prefix(100))")
            if let n = p.agentName { lines.append("agentName: \(n)") }
            if !p.attachments.isEmpty { lines.append("attachments: \(p.attachments.count)") }
            if !p.responseSuggestions.isEmpty {
                lines.append("suggestions: \(p.responseSuggestions.map { $0.messageText }.joined(separator: ", "))")
            }
            lines.append("endConversation: \(p.endConversation)")
        case .agentMessageChunk(_, let p):
            lines.append("messageId: \(p.messageId)")
            lines.append("chunkIndex: \(p.chunkIndex)")
            lines.append("isComplete: \(p.isComplete)")
            if let t = p.text { lines.append("text: \(t.prefix(80))") }
        case .liveAgentMessage(_, let p):
            lines.append("messageId: \(p.messageId)")
            lines.append("text: \(p.text.prefix(100))")
        case .systemMessage(_, let p):
            lines.append("level: \(p.level)")
            lines.append("message: \(p.message)")
        case .connected:
            lines.append("status: connected")
        case .disconnected(let err):
            lines.append("error: \(err?.localizedDescription ?? "none")")
        case .reconnecting(let a):
            lines.append("attempt: \(a)")
        default:
            break
        }
        return lines.joined(separator: "\n")
    }
}

private func formatDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: date)
}
