// Copyright PolyAI Limited

import Foundation
import Combine

/// A reusable, persisted bag of developer/runtime knobs for building a
/// ``Configuration`` at runtime — useful for QA playgrounds, internal builds,
/// and protocol testing. Backed by `UserDefaults`, observable from both
/// SwiftUI (`@StateObject` / `@ObservedObject`) and UIKit (Combine `sink`).
///
/// The API key is taken from the config you passed to
/// ``PolyMessaging/initialize(_:)`` — call `initialize` first, then construct
/// `DevSettings()` with no arguments. The default environment is seeded from
/// that same config, and the `X-Host` is derived from the selected environment
/// (override with `hostIdentifier:` if you need to). Nothing is hardcoded, so
/// the SDK never ships credentials.
///
/// Subclass and override `buildConfiguration()` (or any `open` member) to
/// customise behaviour.
///
///     PolyMessaging.initialize(.init(apiKey: "..."))   // defaults to .us
///     let settings = DevSettings()
///     let session = PolyMessaging.chat(settings.buildConfiguration())
@MainActor
open class DevSettings: ObservableObject {

    /// The set of environments the settings UI can switch between. Maps onto
    /// the SDK's ``Environment`` in `resolvedEnvironment()`.
    public enum EnvironmentKind: Int, CaseIterable, Identifiable, Sendable {
        case us = 0
        case uk = 1
        case euw = 2
        case cluster = 3
        case custom = 4

        public var id: Int { rawValue }

        public var displayName: String {
            switch self {
            case .us: return "Production US"
            case .uk: return "Production UK"
            case .euw: return "Production EU West"
            case .cluster: return "Cluster"
            case .custom: return "Custom URLs"
            }
        }
    }

    // MARK: - Non-persisted inputs

    private let hostIdentifierOverride: String?
    private let defaultEnvironmentKind: EnvironmentKind
    private let defaults: UserDefaults
    private let keyPrefix: String

    // MARK: - Persisted settings

    @Published public var environmentKind: EnvironmentKind { didSet { persist("environmentKind", environmentKind.rawValue) } }
    @Published public var clusterName: String { didSet { persist("clusterName", clusterName) } }
    @Published public var customRestURL: String { didSet { persist("customRestURL", customRestURL) } }
    @Published public var customWsURL: String { didSet { persist("customWsURL", customWsURL) } }

    @Published public var streamingEnabled: Bool { didSet { persist("streamingEnabled", streamingEnabled) } }
    @Published public var logLevel: LogLevel { didSet { persist("logLevel", logLevel.rawValue) } }
    /// 0 = use SDK default (600s = 10 min, matches backend WS idle timeout).
    @Published public var sessionTimeoutSeconds: Int { didSet { persist("sessionTimeoutSeconds", sessionTimeoutSeconds) } }
    /// 0 = use SDK default (30s).
    @Published public var heartbeatIntervalSeconds: Int { didSet { persist("heartbeatIntervalSeconds", heartbeatIntervalSeconds) } }
    /// 0 = use SDK default (10).
    @Published public var maxReconnectAttempts: Int { didSet { persist("maxReconnectAttempts", maxReconnectAttempts) } }

    @Published public var showDebugStrip: Bool { didSet { persist("showDebugStrip", showDebugStrip) } }
    @Published public var showMessageTimestamps: Bool { didSet { persist("showMessageTimestamps", showMessageTimestamps) } }

    /// The `streamingEnabled` value baked into the most recently created session.
    /// Call `recordSessionApplied()` after a fresh session is created so a UI can
    /// warn that a changed `streamingEnabled` only applies on the next restart.
    @Published public private(set) var lastAppliedStreamingEnabled: Bool { didSet { persist("lastAppliedStreamingEnabled", lastAppliedStreamingEnabled) } }

    // MARK: - Init

    /// Call ``PolyMessaging/initialize(_:)`` first — the API key and the
    /// seed environment are read from that config.
    ///
    /// - Parameters:
    ///   - hostIdentifier: Optional `X-Host` override. nil = derive from the
    ///     selected environment (or inherit from the initialize config).
    ///   - defaultEnvironment: Optional override for the initial environment
    ///     selection. nil = seed from the initialize config's environment.
    public init(
        hostIdentifier: String? = nil,
        defaultEnvironment: EnvironmentKind? = nil,
        defaults: UserDefaults = .standard,
        keyPrefix: String = "ai.poly.messaging.devsettings."
    ) {
        self.hostIdentifierOverride = hostIdentifier
        self.defaults = defaults
        self.keyPrefix = keyPrefix

        let baseEnvironment = PolyMessaging.currentConfig.environment
        let seedKind = defaultEnvironment ?? Self.kind(for: baseEnvironment)
        self.defaultEnvironmentKind = seedKind

        // Seed cluster name / custom URLs from the initialize config so the
        // picker reflects the active environment on first launch.
        var seedCluster = "us-1"
        var seedRest = ""
        var seedWs = ""
        switch baseEnvironment {
        case .cluster(let name): seedCluster = name
        case .custom(let rest, let ws): seedRest = rest.absoluteString; seedWs = ws.absoluteString
        default: break
        }

        // didSet does not fire for assignments inside init, so these load the
        // persisted value (or the seed default) without re-writing it.
        self.environmentKind = (defaults.object(forKey: keyPrefix + "environmentKind") as? Int)
            .flatMap(EnvironmentKind.init(rawValue:)) ?? seedKind
        self.clusterName = defaults.string(forKey: keyPrefix + "clusterName") ?? seedCluster
        self.customRestURL = defaults.string(forKey: keyPrefix + "customRestURL") ?? seedRest
        self.customWsURL = defaults.string(forKey: keyPrefix + "customWsURL") ?? seedWs
        self.streamingEnabled = (defaults.object(forKey: keyPrefix + "streamingEnabled") as? Bool) ?? true
        self.logLevel = (defaults.object(forKey: keyPrefix + "logLevel") as? Int)
            .flatMap(LogLevel.init(rawValue:)) ?? .debug
        self.sessionTimeoutSeconds = defaults.integer(forKey: keyPrefix + "sessionTimeoutSeconds")
        self.heartbeatIntervalSeconds = defaults.integer(forKey: keyPrefix + "heartbeatIntervalSeconds")
        self.maxReconnectAttempts = defaults.integer(forKey: keyPrefix + "maxReconnectAttempts")
        self.showDebugStrip = (defaults.object(forKey: keyPrefix + "showDebugStrip") as? Bool) ?? false
        self.showMessageTimestamps = (defaults.object(forKey: keyPrefix + "showMessageTimestamps") as? Bool) ?? true
        self.lastAppliedStreamingEnabled = (defaults.object(forKey: keyPrefix + "lastAppliedStreamingEnabled") as? Bool) ?? true
    }

    private static func kind(for environment: Environment) -> EnvironmentKind {
        switch environment {
        case .us: return .us
        case .uk: return .uk
        case .euw: return .euw
        case .cluster: return .cluster
        case .custom: return .custom
        }
    }

    // MARK: - Derived

    /// Maps `environmentKind` (+ cluster name / custom URLs) onto the SDK ``Environment``.
    open func resolvedEnvironment() -> Environment {
        switch environmentKind {
        case .us: return .us
        case .uk: return .uk
        case .euw: return .euw
        case .cluster:
            let name = clusterName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? .us : .cluster(name)
        case .custom:
            if let r = URL(string: customRestURL), let w = URL(string: customWsURL) {
                return .custom(restBaseURL: r, wsBaseURL: w)
            }
            return .us
        }
    }

    /// A short, human-readable label for the resolved environment host.
    open func environmentDisplayName() -> String {
        switch environmentKind {
        case .us: return "messaging.us-1.poly.ai"
        case .uk: return "messaging.uk-1.poly.ai"
        case .euw: return "messaging.euw-1.poly.ai"
        case .cluster:
            let name = clusterName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "(missing cluster)" : "messaging.\(name).poly.ai"
        case .custom:
            return URL(string: customRestURL)?.host ?? "(custom)"
        }
    }

    /// True when any knob differs from the seeded defaults — useful for a
    /// "custom settings active" badge.
    open var hasCustomization: Bool {
        environmentKind != defaultEnvironmentKind
        || !streamingEnabled
        || logLevel != .debug
        || sessionTimeoutSeconds > 0
        || heartbeatIntervalSeconds > 0
        || maxReconnectAttempts > 0
    }

    open func resetToDefaults() {
        environmentKind = defaultEnvironmentKind
        clusterName = "us-1"
        customRestURL = ""
        customWsURL = ""
        streamingEnabled = true
        logLevel = .debug
        sessionTimeoutSeconds = 0
        heartbeatIntervalSeconds = 0
        maxReconnectAttempts = 0
    }

    open func recordSessionApplied() {
        lastAppliedStreamingEnabled = streamingEnabled
    }

    /// Builds a ``Configuration`` from the `initialize(_:)` API key and
    /// the current runtime knobs. The `X-Host` is left to the SDK to derive from
    /// the selected environment unless a `hostIdentifier` override was supplied.
    /// Override this method to customise.
    open func buildConfiguration() -> Configuration {
        let base = PolyMessaging.currentConfig

        return Configuration(
            apiKey: base.apiKey,
            environment: resolvedEnvironment(),
            hostIdentifier: hostIdentifierOverride ?? base.hostIdentifier,
            streamingEnabled: streamingEnabled,
            logLevel: logLevel,
            heartbeatIntervalSeconds: heartbeatIntervalSeconds > 0 ? heartbeatIntervalSeconds : nil,
            sessionTimeoutSeconds: sessionTimeoutSeconds > 0 ? sessionTimeoutSeconds : nil,
            maxReconnectAttempts: maxReconnectAttempts > 0 ? maxReconnectAttempts : nil
        )
    }

    // MARK: - Persistence

    private func persist(_ key: String, _ value: Any) {
        defaults.set(value, forKey: keyPrefix + key)
    }
}
