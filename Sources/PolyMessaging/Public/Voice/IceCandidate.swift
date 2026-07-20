// Copyright PolyAI Limited

import Foundation

/// An ICE candidate exchanged with the WebRTC signaling gateway.
///
/// Public so the PolyVoice product's WebRTC engine can produce and consume them
/// across the module boundary — see ``CallMediaEngine``.
public struct IceCandidate: Sendable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int?

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}
