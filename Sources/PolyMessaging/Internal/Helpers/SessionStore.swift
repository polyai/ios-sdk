// Copyright PolyAI Limited

import Foundation
import CryptoKit

struct SessionStore: Sendable {
    private static let basePrefix = "ai.poly.messaging."

    /// Per-connector-token namespace. Hash (not the token itself) is appended
    /// so two `Configuration`s with different tokens don't share session
    /// state on disk. Web's SessionStoreAdapter does the same.
    private let tokenNamespace: String

    /// Default initializer (used by tests and pre-tokenized contexts).
    init() {
        self.tokenNamespace = ""
    }

    init(apiKey: String) {
        // SHA-256 truncated to 8 hex chars — collision-resistant enough for
        // local disk isolation and short enough to keep keys readable.
        let hash = SHA256.hash(data: Data(apiKey.utf8))
        let hex = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        self.tokenNamespace = hex + "."
    }

    private func key(_ suffix: String) -> String {
        Self.basePrefix + tokenNamespace + suffix
    }

    /// Persists the session triple so cross-launch resume reconnects as the
    /// SAME user identity (not just the same session_id). Each call to
    /// `/access-token` mints a fresh user — restoring a stale token would
    /// fail server-side because the session is owned by the original user.
    /// Web's `BrowserSessionStoreAdapter` keeps `ACCESS_TOKEN` in localStorage
    /// for the same reason.
    func save(sessionId: String, accessToken: String, timestamp: Date, tokenExpiresAt: Date? = nil) {
        UserDefaults.standard.set(sessionId, forKey: key("sessionId"))
        UserDefaults.standard.set(accessToken, forKey: key("accessToken"))
        UserDefaults.standard.set(timestamp.timeIntervalSince1970, forKey: key("lastActivity"))
        if let expiresAt = tokenExpiresAt {
            UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: key("tokenExpiresAt"))
        } else {
            UserDefaults.standard.removeObject(forKey: key("tokenExpiresAt"))
        }
    }

    func load() -> (sessionId: String, accessToken: String?, timestamp: Date, tokenExpiresAt: Date?)? {
        guard let id = UserDefaults.standard.string(forKey: key("sessionId")) else {
            return nil
        }
        let token = UserDefaults.standard.string(forKey: key("accessToken"))
        let ts = UserDefaults.standard.double(forKey: key("lastActivity"))
        let expiresAtTs = UserDefaults.standard.double(forKey: key("tokenExpiresAt"))
        let tokenExpiresAt: Date? = expiresAtTs > 0 ? Date(timeIntervalSince1970: expiresAtTs) : nil
        return (id, token, Date(timeIntervalSince1970: ts), tokenExpiresAt)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key("sessionId"))
        UserDefaults.standard.removeObject(forKey: key("accessToken"))
        UserDefaults.standard.removeObject(forKey: key("lastActivity"))
        UserDefaults.standard.removeObject(forKey: key("tokenExpiresAt"))
    }

    func isTokenExpiringSoon(thresholdSeconds: TimeInterval = 300) -> Bool {
        let expiresAtTs = UserDefaults.standard.double(forKey: key("tokenExpiresAt"))
        guard expiresAtTs > 0 else { return false }
        let expiresAt = Date(timeIntervalSince1970: expiresAtTs)
        return expiresAt.timeIntervalSinceNow < thresholdSeconds
    }

    func updateTimestamp(_ date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key("lastActivity"))
    }
}
