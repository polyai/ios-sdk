import Foundation

public struct Configuration: Sendable {
    public let connectorToken: String
    public let environment: Environment
    /// When nil, defaults to the app's bundle identifier (e.g. `com.yourcompany.app`).
    /// Must match the host domain registered in Agent Studio when generating the connector token.
    public let hostIdentifier: String?
    public let streamingEnabled: Bool
    public let logLevel: LogLevel
    /// Override the default heartbeat interval (30s). Server `SessionCapabilities`
    /// still overrides this once the session is established.
    public let heartbeatIntervalSeconds: Int?
    /// Override the default session idle timeout (600s = 10 min). Mirrors the
    /// backend's WebSocket idle timeout — sessions still alive on the server
    /// can be resumed within this window; older ones are gone.
    public let sessionTimeoutSeconds: Int?
    /// Override the default max-reconnect attempts (10). Server `SessionCapabilities`
    /// still overrides this once the session is established.
    public let maxReconnectAttempts: Int?
    public init(
        connectorToken: String,
        environment: Environment,
        hostIdentifier: String? = nil,
        streamingEnabled: Bool = true,
        logLevel: LogLevel = .error,
        heartbeatIntervalSeconds: Int? = nil,
        sessionTimeoutSeconds: Int? = nil,
        maxReconnectAttempts: Int? = nil
    ) {
        self.connectorToken = connectorToken
        self.environment = environment
        self.hostIdentifier = hostIdentifier
        self.streamingEnabled = streamingEnabled
        self.logLevel = logLevel
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.maxReconnectAttempts = maxReconnectAttempts
    }
}

#if false
public enum CertificatePinning: Sendable, Equatable {
    case none
    case spki(sha256Hashes: Set<Data>)
    case certificate(sha256Hashes: Set<Data>)
}
#endif

public enum Environment: Sendable {
    case production
    case staging
    case dev
    case custom(restBaseURL: URL, wsBaseURL: URL)
    /// Named cluster, e.g. `.cluster("us-1")`, `.cluster("uk-1")`, `.cluster("euw-1")`.
    case cluster(String)
}

public enum Platform: String, Sendable {
    case ios
}

public enum LogLevel: Int, Sendable, Comparable {
    case none = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
