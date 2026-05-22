import Foundation

/// An ICE candidate exchanged with the WebRTC signaling gateway.
struct ICECandidate: Sendable, Equatable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int?
}

/// A parsed inbound signal from the WebRTC signaling gateway
/// (`/api/v1/webrtc/signal`).
enum InboundSignal: Sendable, Equatable {
    case answer(sessionId: String?, sdp: String)
    case iceCandidate(ICECandidate)
    case error(message: String)
    case pong
    /// Backend-initiated session close (e.g. the agent finished its turn).
    case close
}

/// Wire framing for the PolyAI WebRTC signaling protocol. Parses inbound
/// gateway frames and builds outbound ones. Pure and stateless — the Swift
/// analogue of the web `polyphoneSignalingProtocolService` /
/// `polyphoneSignalingSocketService` send helpers.
enum SignalingProtocol {

    // MARK: - Inbound

    /// Parse a raw inbound frame. Returns nil for malformed / unknown frames.
    static func parse(_ data: Data) -> InboundSignal? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? WireJSON,
              let type = json.string("type") else {
            return nil
        }

        switch type {
        case "answer":
            guard let payload = json.dict("data"), let sdp = payload.string("sdp") else { return nil }
            return .answer(sessionId: json.string("sessionId"), sdp: sdp)
        case "ice-candidate":
            guard let payload = json.dict("data"), let candidate = payload.string("candidate") else { return nil }
            return .iceCandidate(ICECandidate(
                candidate: candidate,
                sdpMid: payload.string("sdpMid"),
                sdpMLineIndex: payload.int("sdpMLineIndex")
            ))
        case "error":
            return .error(message: json.dict("data")?.string("message") ?? "Connection failed")
        case "pong":
            return .pong
        case "close":
            return .close
        default:
            return nil
        }
    }

    // MARK: - Outbound

    /// The initial SDP offer with auth + call metadata. `sessionId` is nil for
    /// a brand-new call (the gateway assigns it and returns it on the answer).
    static func offer(sdp: String, authToken: String, callSid: String, sessionId: String?) -> Data? {
        var msg: [String: Any] = [
            "type": "offer",
            "data": ["type": "offer", "sdp": sdp],
            "mode": "end-to-end",
            "authToken": authToken,
            "callSid": callSid,
            "caller": "Polyphone",
            "callee": "Polyphone",
        ]
        // The web client sends an explicit JSON null when the session is new.
        if let sessionId { msg["sessionId"] = sessionId } else { msg["sessionId"] = NSNull() }
        return try? JSONSerialization.data(withJSONObject: msg)
    }

    /// An outbound local ICE candidate (sent once the session ID is known).
    static func iceCandidate(_ candidate: ICECandidate, sessionId: String) -> Data? {
        var data: [String: Any] = ["candidate": candidate.candidate]
        if let mid = candidate.sdpMid { data["sdpMid"] = mid }
        if let idx = candidate.sdpMLineIndex { data["sdpMLineIndex"] = idx }
        return try? JSONSerialization.data(withJSONObject: [
            "type": "ice-candidate",
            "sessionId": sessionId,
            "data": data,
        ])
    }

    /// A graceful close frame.
    static func close(sessionId: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["type": "close", "sessionId": sessionId])
    }
}
