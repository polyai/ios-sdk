// Copyright PolyAI Limited

import Foundation

struct VoiceEnvironment: Sendable {
    let signalingURL: URL
    private let gatewayHost: String

    /// - Parameter signalingHost: overrides the derived host (self-hosted / dev gateway);
    ///   **required** for `.custom`. Mirrors Android's `VoiceHosts` rule: `dev` is standalone,
    ///   every other region/cluster lives under the `.platform` subdomain.
    init(environment: Environment, signalingHost: String? = nil) throws {
        let host: String
        if let signalingHost, !signalingHost.isEmpty {
            host = signalingHost
        } else {
            switch environment {
            case .us:  host = "webrtc-gateway.us-1.platform.polyai.app"
            case .uk:  host = "webrtc-gateway.uk-1.platform.polyai.app"
            case .euw: host = "webrtc-gateway.euw-1.platform.polyai.app"
            case .cluster(let name):
                host = name == "dev"
                    ? "webrtc-gateway.dev.polyai.app"
                    : "webrtc-gateway.\(name).platform.polyai.app"
            case .custom:
                throw PolyError.invalidConfiguration(
                    "Voice on a .custom environment requires VoiceOptions.signalingHost")
            }
        }
        gatewayHost = host
        guard let url = URL(string: "wss://\(host)/api/v1/webrtc/signal") else {
            throw PolyError.invalidConfiguration("Invalid voice signaling host: \(host)")
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
