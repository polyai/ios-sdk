// Copyright PolyAI Limited

import Foundation
import CryptoKit
import Security

struct SessionStore: Sendable {
    private static let basePrefix = "ai.poly.messaging."
    private static let keychainService = "ai.poly.messaging"

    private let tokenNamespace: String

    init() {
        self.tokenNamespace = ""
    }

    init(apiKey: String) {
        let hash = SHA256.hash(data: Data(apiKey.utf8))
        let hex = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        self.tokenNamespace = hex + "."
    }

    private func key(_ suffix: String) -> String {
        Self.basePrefix + tokenNamespace + suffix
    }

    private var keychainAccount: String {
        key("accessToken")
    }

    func save(sessionId: String, accessToken: String, timestamp: Date, tokenExpiresAt: Date? = nil) {
        UserDefaults.standard.set(sessionId, forKey: key("sessionId"))
        UserDefaults.standard.set(timestamp.timeIntervalSince1970, forKey: key("lastActivity"))
        if let expiresAt = tokenExpiresAt {
            UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: key("tokenExpiresAt"))
        } else {
            UserDefaults.standard.removeObject(forKey: key("tokenExpiresAt"))
        }
        saveTokenToKeychain(accessToken)
    }

    func load() -> (sessionId: String, accessToken: String?, timestamp: Date, tokenExpiresAt: Date?)? {
        guard let id = UserDefaults.standard.string(forKey: key("sessionId")) else {
            return nil
        }
        let token = loadTokenFromKeychain()
        let ts = UserDefaults.standard.double(forKey: key("lastActivity"))
        let expiresAtTs = UserDefaults.standard.double(forKey: key("tokenExpiresAt"))
        let tokenExpiresAt: Date? = expiresAtTs > 0 ? Date(timeIntervalSince1970: expiresAtTs) : nil
        return (id, token, Date(timeIntervalSince1970: ts), tokenExpiresAt)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key("sessionId"))
        UserDefaults.standard.removeObject(forKey: key("lastActivity"))
        UserDefaults.standard.removeObject(forKey: key("tokenExpiresAt"))
        deleteTokenFromKeychain()
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

    // MARK: - Keychain

    private func saveTokenToKeychain(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        deleteTokenFromKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteTokenFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
