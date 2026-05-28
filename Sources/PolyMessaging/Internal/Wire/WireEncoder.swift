// Copyright PolyAI Limited

import Foundation

enum WireEncoder {

    static func encode(_ event: OutgoingEvent) -> Data? {
        // Serialise every outgoing event the backend accepts: HEARTBEAT,
        // USER_TYPING, USER_MESSAGE, USER_END_SESSION, REQUEST_POLY_AGENT_JOIN.
        // Heartbeat in particular keeps the session alive — the server refreshes
        // the session on each one and echoes it back, so dropping it client-side
        // caused quiet chats to hit the server-side idle expiry and removed our
        // WS liveness echo.
        guard let wireType = wireType(for: event) else { return nil }

        var frame: WireJSON = ["type": wireType]

        switch event {
        case .userMessage(let text, let metadata):
            frame["payload"] = ["text": text] as WireJSON
            if let metadata {
                frame["metadata"] = ["custom": metadata] as WireJSON
            }
        case .userTyping(let state):
            frame["payload"] = ["state": state.rawValue] as WireJSON
        case .requestPolyAgentJoin,
             .heartbeat,
             .userEndConversation,
             .userLeft:
            // Server schema requires `payload` to be a (possibly empty) object.
            frame["payload"] = [:] as WireJSON
        }

        return try? JSONSerialization.data(withJSONObject: frame)
    }

    private static func wireType(for event: OutgoingEvent) -> String? {
        switch event {
        case .userMessage:              return WireEventType.userMessage.rawValue
        // UserEndConversation + UserLeft both collapse to USER_END_SESSION —
        
        case .userEndConversation,
             .userLeft:                 return WireEventType.userEndSession.rawValue
        case .requestPolyAgentJoin:     return WireEventType.requestPolyAgentJoin.rawValue
        case .userTyping:               return WireEventType.userTyping.rawValue
        case .heartbeat:                return WireEventType.heartbeat.rawValue
        }
    }
}
