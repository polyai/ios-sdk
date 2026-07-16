// Copyright PolyAI Limited

import Foundation

struct VoiceEnvironment: Sendable {
    let signalingURL: URL
    private let gatewayHost: String
    private let gatewayPort: Int?

    /// - Parameter signalingHost: overrides the derived host (self-hosted / dev gateway);
    ///   **required** for `.custom`. The host rule: `dev` is standalone,
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
        // A signalingHost may carry a port ("localhost:8443"). URLComponents.host
        // rejects "host:port", so split it here — the ICE URL below sets the port
        // separately instead of silently producing a nil URL (which would drop the
        // TURN fetch and fall back to public STUN).
        (gatewayHost, gatewayPort) = Self.splitPort(host)
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
        components.port = gatewayPort
        components.path = "/api/v1/ice-servers"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    /// Split a trailing `:port` off a host string. Leaves anything that isn't a
    /// plain host:port pair (no port, or an IPv6 literal) untouched.
    private static func splitPort(_ host: String) -> (String, Int?) {
        guard !host.hasPrefix("["), // IPv6 literals keep their brackets — no split
              let colon = host.lastIndex(of: ":"),
              let port = Int(host[host.index(after: colon)...]),
              (1...65535).contains(port) else {
            return (host, nil)
        }
        return (String(host[..<colon]), port)
    }
}
