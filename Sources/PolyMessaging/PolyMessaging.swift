import Foundation

public enum PolyMessaging {

    /// Matches the backend's WebSocket idle timeout (10 min). Sessions older
    /// than this have been killed server-side, so offering "Resume" would 404.
    private static let resumeWindowSeconds: TimeInterval = 600
    private static var _config: Configuration?

    /// Call once at app launch (e.g. in `App.init` or `application(_:didFinishLaunching:)`).
    /// After this, `chat()` and `start()` work with no arguments.
    ///
    ///     PolyMessaging.initialize(.init(
    ///         connectorToken: "ct_live_...",
    ///         environment: .cluster("us-1")
    ///     ))
    public static func initialize(_ config: Configuration) {
        precondition(!config.connectorToken.isEmpty, "PolyMessaging: connectorToken must not be empty")
        _config = config
    }

    static var currentConfig: Configuration {
        guard let config = _config else {
            preconditionFailure("PolyMessaging: call initialize(_:) before using the SDK")
        }
        return config
    }

    @discardableResult
    public static func configure(_ config: Configuration) throws -> PolyMessagingClient {
        guard !config.connectorToken.isEmpty else {
            throw PolyError.invalidConfiguration("connectorToken must not be empty")
        }
        return PolyMessagingClient(config: config)
    }

    private static func makeClient(_ config: Configuration) -> PolyMessagingClient {
        precondition(!config.connectorToken.isEmpty, "PolyMessaging: connectorToken must not be empty")
        return PolyMessagingClient(config: config)
    }

    /// True when a previously-persisted session for this connector token can
    /// still be resumed. Use this to drive UI decisions like showing a
    /// "Resume Chat" button. A `true` return means:
    ///   - The stored session row is within the idle window (~10 min).
    ///   - The stored access token is structurally valid and unexpired.
    /// Both halves are required: restoring half a session creates a
    /// mismatched user identity and the server rejects the connection.
    ///
    /// Reading is side-effect-free — no SDK state is mutated, no network
    /// call is made. Safe to call from any thread before `configure(...)`.
    public static func hasResumableSession(connectorToken: String) -> Bool {
        guard !connectorToken.isEmpty else { return false }
        let store = SessionStore(connectorToken: connectorToken)
        guard let stored = store.load() else { return false }
        guard Date().timeIntervalSince(stored.timestamp) < resumeWindowSeconds else { return false }
        guard let token = stored.accessToken else { return false }
        return JWTValidator.isStructurallyValid(token)
    }

    /// Wipe the persisted session for this connector token.
    ///
    /// You don't need this if you use `start(...)` — it clears the store
    /// automatically. This method exists for the lower-level `configure(...)`
    /// path where you need to clear persisted state before the SDK's
    /// lazy-start resumes the prior session.
    ///
    /// Side-effect-free with respect to the SDK in memory — only touches
    /// the on-disk store (`SessionStore`). Safe to call from any thread.
    public static func clearResumableSession(connectorToken: String) {
        guard !connectorToken.isEmpty else { return }
        SessionStore(connectorToken: connectorToken).clear()
    }

    public static func hasResumableSession() -> Bool {
        hasResumableSession(connectorToken: currentConfig.connectorToken)
    }

    public static func clearResumableSession() {
        clearResumableSession(connectorToken: currentConfig.connectorToken)
    }

    // MARK: - One-shot API

    /// Uses the config from `initialize(_:)`. Call `initialize` first.
    ///
    /// - Parameter streamingEnabled: optional per-session override. `nil` (the
    ///   default) uses `Configuration.streamingEnabled` from `initialize(...)`.
    @MainActor
    public static func chat(streamingEnabled: Bool? = nil) -> ChatSession {
        chat(currentConfig, streamingEnabled: streamingEnabled)
    }

    /// The recommended entry point with full configuration. Resumes an
    /// existing session if one is available, otherwise creates a fresh one.
    ///
    ///     let session = PolyMessaging.chat(.init(
    ///         connectorToken: "ct_live_...",
    ///         environment: .cluster("us-1"),
    ///         streamingEnabled: true
    ///     ))
    ///
    /// - Parameter streamingEnabled: optional per-session override of the
    ///   `Configuration.streamingEnabled` default. `nil` keeps the default.
    @MainActor
    public static func chat(_ config: Configuration, streamingEnabled: Bool? = nil) -> ChatSession {
        let client = makeClient(config)
        return ChatSession(client: client, streamingEnabled: streamingEnabled)
    }

    /// - Parameter streamingEnabled: see ``chat(_:streamingEnabled:)``.
    @MainActor
    public static func start(streamingEnabled: Bool? = nil) -> ChatSession {
        start(currentConfig, streamingEnabled: streamingEnabled)
    }

    /// Create a fresh chat session with full configuration.
    ///
    /// - Parameter streamingEnabled: see ``chat(_:streamingEnabled:)``.
    @MainActor
    public static func start(_ config: Configuration, streamingEnabled: Bool? = nil) -> ChatSession {
        clearResumableSession(connectorToken: config.connectorToken)
        let client = makeClient(config)
        return ChatSession(client: client, streamingEnabled: streamingEnabled)
    }

    @available(*, deprecated, renamed: "chat")
    @MainActor
    public static func resume(_ config: Configuration, streamingEnabled: Bool? = nil) -> ChatSession {
        chat(config, streamingEnabled: streamingEnabled)
    }

    // MARK: - Voice

    /// Create a voice call using the config from `initialize(_:)`. Call
    /// `start()` on the result to place it (mirrors `chat()`).
    ///
    /// Voice calling is not yet available: the SDK ships without an on-device
    /// media (WebRTC audio) engine, so `start()` surfaces
    /// `PolyError.voice(.notImplemented)`.
    public static func voice() -> PolyCall {
        voice(currentConfig)
    }

    /// Create a voice call with full configuration. See ``voice()``.
    public static func voice(_ config: Configuration) -> PolyCall {
        PolyCall(config: config)
    }
}
