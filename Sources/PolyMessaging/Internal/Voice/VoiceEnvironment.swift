// Copyright PolyAI Limited

import Foundation

/// Resolves the WebRTC signaling gateway URL per environment, mirroring how
/// `EnvironmentURLs` resolves the messaging REST/WS hosts.
///
/// The gateway lives on a sibling host of the messaging service
/// (`webrtc-gateway.<env>.polyai.app`). `.custom` has no known gateway, so it
/// falls back to dev.
struct VoiceEnvironment: Sendable {
    let signalingURL: URL

    init(environment: Environment) {
        let host: String
        switch environment {
        case .production:
            host = "webrtc-gateway.polyai.app"
        case .staging:
            host = "webrtc-gateway.staging.polyai.app"
        case .dev:
            host = "webrtc-gateway.dev.polyai.app"
        case .cluster(let name):
            host = "webrtc-gateway.\(name).polyai.app"
        case .custom:
            host = "webrtc-gateway.dev.polyai.app"
        }
        signalingURL = URL(string: "wss://\(host)/api/v1/webrtc/signal")!
    }
}
