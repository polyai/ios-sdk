// Copyright PolyAI Limited

import Foundation

/// State of the underlying media (WebRTC peer) connection.
enum CallMediaState: Sendable, Equatable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// The media (WebRTC peer-connection) seam that the call pipeline drives.
///
/// The SDK ships **without** a built-in implementation: real WebRTC audio on
/// iOS requires a peer-connection engine (DTLS-SRTP / Opus) that a zero-
/// dependency package can't provide on its own. That's why the public
/// `call()` surfaces `PolyError.voice(.notImplemented)`.
///
/// The protocol is kept internal so the signaling pipeline can still be
/// exercised end-to-end — over a mock in unit tests and against the live
/// gateway in the opt-in integration probe — by injecting an engine that
/// produces a valid SDP offer. When a real engine is supplied, the same
/// `CallCoordinator` carries audio with no further changes.
protocol CallMediaEngine: Sendable {
    /// Acquire the microphone and produce the local SDP offer (audio).
    func createOffer() async throws -> String
    /// Apply the remote SDP answer returned by the gateway.
    func acceptAnswer(sdp: String) async throws
    /// Add a remote ICE candidate received from the gateway.
    func addRemoteCandidate(_ candidate: ICECandidate) async throws
    /// Register the sink for locally-gathered ICE candidates (forwarded to the
    /// gateway by the pipeline).
    func setLocalCandidateHandler(_ handler: @escaping @Sendable (ICECandidate) -> Void) async
    /// Register the sink for media connection-state transitions.
    func setStateHandler(_ handler: @escaping @Sendable (CallMediaState) -> Void) async
    /// Mute / unmute the local microphone track.
    func setMuted(_ muted: Bool) async
    /// Tear down the peer connection and release the microphone.
    func close() async
}
