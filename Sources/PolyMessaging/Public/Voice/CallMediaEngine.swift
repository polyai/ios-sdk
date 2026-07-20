// Copyright PolyAI Limited

import Foundation

/// State of the underlying media (WebRTC peer) connection.
public enum CallMediaState: Sendable, Equatable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

/// An audio-session interruption relevant to a live call (phone call, Siri, another app).
public enum CallInterruption: Sendable, Equatable {
    /// Audio was taken — mute the mic until the interruption ends.
    case began
    /// The interruption ended and the system says it's safe to resume — unmute.
    case endedResume
    /// The interruption ended but the system won't let us resume — end the call.
    case endedStop
}

/// The media (WebRTC peer-connection) seam that the call pipeline drives.
///
/// `PolyMessaging` is dependency-free and so ships no implementation: real
/// WebRTC audio needs a peer-connection engine (DTLS-SRTP / Opus) that a
/// zero-dependency package can't provide. `PolyVoice` supplies one, and this
/// protocol is `public` purely so it can do that across the module boundary.
///
/// > Important: This is an **SDK-internal seam, not a stable extension point.**
/// > It exists for `PolyVoice` (and for injecting a stub in the SDK's own
/// > tests). Conform to it outside the SDK at your own risk: capability
/// > methods will be added here in minor releases. Everything with a default
/// > implementation below is additive-safe; the core requirements are not.
@_spi(PolyVoice)
public protocol CallMediaEngine: Sendable {
    /// Acquire the microphone and produce the local SDP offer (audio), building
    /// the peer connection with the supplied ICE (STUN/TURN) servers.
    func createOffer(iceServers: [IceServer]) async throws -> String
    /// Apply the remote SDP answer returned by the gateway.
    func acceptAnswer(sdp: String) async throws
    /// Add a remote ICE candidate received from the gateway.
    func addRemoteCandidate(_ candidate: IceCandidate) async throws
    /// Register the sink for locally-gathered ICE candidates (forwarded to the
    /// gateway by the pipeline).
    func setLocalCandidateHandler(_ handler: @escaping @Sendable (IceCandidate) -> Void) async
    /// Register the sink for media connection-state transitions.
    func setStateHandler(_ handler: @escaping @Sendable (CallMediaState) -> Void) async
    /// Register the sink for audio-session interruptions (phone calls, Siri, etc.).
    func setInterruptionHandler(_ handler: @escaping @Sendable (CallInterruption) -> Void) async
    /// Register the sink for audio-routing snapshots (available outputs + the active one).
    func setAudioStateHandler(_ handler: @escaping @Sendable (AudioState) -> Void) async
    /// Route call audio to `device`, or `nil` to revert to automatic routing.
    func selectAudioDevice(_ device: AudioDevice?) async
    /// Mute / unmute the local microphone track.
    func setMuted(_ muted: Bool) async
    /// Tear down the peer connection and release the microphone.
    func close() async
}

// MARK: - Optional capabilities

/// Defaults for the requirements an engine can legitimately not implement, so
/// adding a capability here is additive rather than a source break for existing
/// conformers.
///
/// Deliberately NOT defaulted: `createOffer`, `acceptAnswer`, `addRemoteCandidate`,
/// `setLocalCandidateHandler`, `setStateHandler`, `setMuted` and `close`. A no-op
/// default on any of those would turn a missing implementation into a silently
/// broken call instead of a compile error — worse than the source break it avoids.
@_spi(PolyVoice)
public extension CallMediaEngine {
    /// Default: no interruption reporting (the call simply won't mute on a
    /// system interruption).
    func setInterruptionHandler(_ handler: @escaping @Sendable (CallInterruption) -> Void) async {}

    /// Default: no audio-routing snapshots (`PolyCall.audioState` stays empty).
    func setAudioStateHandler(_ handler: @escaping @Sendable (AudioState) -> Void) async {}

    /// Default: routing is left entirely to the system.
    func selectAudioDevice(_ device: AudioDevice?) async {}
}
