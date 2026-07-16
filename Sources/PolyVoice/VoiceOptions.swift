// Copyright PolyAI Limited

import Foundation

/// Options for ``PolyVoice/call(config:options:)``.
///
/// `webrtcToken` is **required** — every voice call needs the WebRTC gateway
/// token, a distinct value from the API key (both come from Agent Studio ›
/// Connector Settings).
public struct VoiceOptions: Sendable {

    /// The connector's WebRTC token — authenticates the signaling offer + the
    /// ICE-servers fetch. Always distinct from `Configuration.apiKey`.
    public let webrtcToken: String

    /// The fallback route when no headset/Bluetooth is connected: the loudspeaker
    /// (hands-free, the `true` default) or the earpiece (`false`). A connected
    /// accessory is always preferred automatically.
    public let speakerphone: Bool

    /// Override the WebRTC gateway host (e.g. a self-hosted or dev gateway). When
    /// nil the host is derived from `Configuration.environment`. **Required** when
    /// the environment is `.custom`.
    public let signalingHost: String?

    public init(webrtcToken: String, speakerphone: Bool = true, signalingHost: String? = nil) {
        self.webrtcToken = webrtcToken
        self.speakerphone = speakerphone
        self.signalingHost = signalingHost
    }
}
