// Copyright PolyAI Limited

import Foundation

struct EnvironmentURLs: Sendable {
    let restBaseURL: URL
    let wsBaseURL: URL

    private static let clusterNamePattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]*$")

    init(environment: Environment) {
        switch environment {
        case .production:
            restBaseURL = URL(string: "https://messaging.poly.ai/api/v1")!
            wsBaseURL = URL(string: "wss://messaging.poly.ai/ws")!
        case .custom(let rest, let ws):
            Self.validateSchemes(rest: rest, ws: ws)
            restBaseURL = rest
            wsBaseURL = ws
        case .cluster(let name):
            Self.validateClusterName(name)
            guard let rest = URL(string: "https://messaging.\(name).poly.ai/api/v1"),
                  let ws = URL(string: "wss://messaging.\(name).poly.ai/ws") else {
                fatalError("PolyMessaging: invalid cluster name '\(name)' — use lowercase alphanumeric with hyphens (e.g. \"us-1\")")
            }
            restBaseURL = rest
            wsBaseURL = ws
        }
    }

    private static func validateSchemes(rest: URL, ws: URL) {
        if rest.scheme != "https" {
            NSLog("[PolyMessaging] WARNING: REST URL uses \(rest.scheme ?? "nil") instead of https — traffic will not be encrypted")
        }
        if ws.scheme != "wss" {
            NSLog("[PolyMessaging] WARNING: WebSocket URL uses \(ws.scheme ?? "nil") instead of wss — traffic will not be encrypted")
        }
    }

    private static func validateClusterName(_ name: String) {
        let range = NSRange(name.startIndex..., in: name)
        guard clusterNamePattern.firstMatch(in: name, range: range) != nil else {
            fatalError("PolyMessaging: invalid cluster name '\(name)' — use lowercase alphanumeric with hyphens (e.g. \"us-1\")")
        }
    }
}
