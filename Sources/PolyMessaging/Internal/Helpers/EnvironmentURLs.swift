// Copyright PolyAI Limited

import Foundation

struct EnvironmentURLs: Sendable {
    let restBaseURL: URL
    let wsBaseURL: URL
    /// Default host-identifier per environment. Used as the `X-Host` header
    /// on `/access-token` requests so the backend can route to the right
    /// connector. `Configuration.hostIdentifier` overrides when non-nil.
    let defaultHostIdentifier: String
    /// True for PolyAI-internal envs (`.dev`, `.staging`) where the connector
    /// token is registered against a fixed infra host (`jupiter-api.dev/staging
    /// .polyai.app/`) rather than the calling app's bundle ID. When true, the
    /// env's `defaultHostIdentifier` takes precedence over `Bundle.main
    /// .bundleIdentifier` so a single `environment: .dev` "just works"
    /// without setting `hostIdentifier`. Customer-facing envs keep bundle ID.
    let preferDefaultHost: Bool

    init(environment: Environment) {
        switch environment {
        case .production:
            restBaseURL = URL(string: "https://messaging.poly.ai/api/v1")!
            wsBaseURL = URL(string: "wss://messaging.poly.ai/ws")!
            defaultHostIdentifier = "https://jupiter-api.polyai.app/"
            preferDefaultHost = false
        case .staging:
            restBaseURL = URL(string: "https://messaging.staging.poly.ai/api/v1")!
            wsBaseURL = URL(string: "wss://messaging.staging.poly.ai/ws")!
            defaultHostIdentifier = "https://jupiter-api.staging.polyai.app/"
            preferDefaultHost = true
        case .dev:
            restBaseURL = URL(string: "https://messaging.dev.poly.ai/api/v1")!
            wsBaseURL = URL(string: "wss://messaging.dev.poly.ai/ws")!
            defaultHostIdentifier = "https://jupiter-api.dev.polyai.app/"
            preferDefaultHost = true
        case .custom(let rest, let ws):
            restBaseURL = rest
            wsBaseURL = ws
            // Custom env keeps the prod default unless the caller overrides
            // via Configuration.hostIdentifier (the existing surface).
            defaultHostIdentifier = "https://jupiter-api.polyai.app/"
            preferDefaultHost = false
        case .cluster(let name):
            restBaseURL = URL(string: "https://messaging.\(name).poly.ai/api/v1")!
            wsBaseURL = URL(string: "wss://messaging.\(name).poly.ai/ws")!
            defaultHostIdentifier = "https://jupiter-api.polyai.app/"
            preferDefaultHost = false
        }
    }
}
