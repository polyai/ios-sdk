// Copyright PolyAI Limited

import Foundation

struct VoiceEnvironment: Sendable {
    let signalingURL: URL
    private let gatewayHost: String

    init(environment: Environment) {
        let host: String
        switch environment {
        case .us:                host = "webrtc-gateway.us-1.polyai.app"
        case .uk:                host = "webrtc-gateway.uk-1.polyai.app"
        case .euw:               host = "webrtc-gateway.euw-1.polyai.app"
        case .cluster(let name): host = "webrtc-gateway.\(name).polyai.app"
        case .custom:            host = "webrtc-gateway.polyai.app"
        }
        gatewayHost = host
        guard let url = URL(string: "wss://\(host)/api/v1/webrtc/signal") else {
            fatalError("PolyMessaging: failed to construct signaling URL for environment")
        }
        signalingURL = url
    }

    /// Gateway ICE-servers endpoint (STUN/TURN) for `token`, e.g.
    /// `https://webrtc-gateway.<region>.polyai.app/api/v1/ice-servers?token=…`.
    /// The token is percent-encoded via `URLComponents`.
    func iceServersURL(token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = gatewayHost
        components.path = "/api/v1/ice-servers"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }
}
