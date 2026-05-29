// Copyright PolyAI Limited

import Foundation

struct EnvironmentURLs: Sendable {
    let restBaseURL: URL
    let wsBaseURL: URL

    private static let clusterNamePattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]*$")

    init(environment: Environment) {
        switch environment {
        case .us:
            (restBaseURL, wsBaseURL) = Self.clusterURLs(for: "us-1")
        case .uk:
            (restBaseURL, wsBaseURL) = Self.clusterURLs(for: "uk-1")
        case .euw:
            (restBaseURL, wsBaseURL) = Self.clusterURLs(for: "euw-1")
        case .custom(let rest, let ws):
            Self.validateSchemes(rest: rest, ws: ws)
            restBaseURL = rest
            wsBaseURL = ws
        case .cluster(let name):
            Self.validateClusterName(name)
            (restBaseURL, wsBaseURL) = Self.clusterURLs(for: name)
        }
    }

    private static func clusterURLs(for name: String) -> (URL, URL) {
        guard let rest = URL(string: "https://messaging.\(name).poly.ai/api/v1"),
              let ws = URL(string: "wss://messaging.\(name).poly.ai/ws") else {
            fatalError("PolyMessaging: invalid cluster name '\(name)' — use lowercase alphanumeric with hyphens (e.g. \"us-1\")")
        }
        return (rest, ws)
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
