// Copyright PolyAI Limited

import Foundation

struct VoiceEnvironment: Sendable {
    let signalingURL: URL

    init(environment: Environment) {
        let host: String
        switch environment {
        case .us:                host = "webrtc-gateway.us-1.polyai.app"
        case .uk:                host = "webrtc-gateway.uk-1.polyai.app"
        case .euw:               host = "webrtc-gateway.euw-1.polyai.app"
        case .cluster(let name): host = "webrtc-gateway.\(name).polyai.app"
        case .custom:            host = "webrtc-gateway.polyai.app"
        }
        guard let url = URL(string: "wss://\(host)/api/v1/webrtc/signal") else {
            fatalError("PolyMessaging: failed to construct signaling URL for environment")
        }
        signalingURL = url
    }
}
