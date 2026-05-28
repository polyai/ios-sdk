// Copyright PolyAI Limited

import Foundation

enum JWTValidator {
    static let clockSkewSeconds: TimeInterval = 5

    static func isStructurallyValid(_ token: String, now: Date = Date()) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }

        let payloadPart = String(parts[1])
        guard let payloadData = base64URLDecode(payloadPart) else { return false }
        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return false
        }

        // No `exp` claim: web treats this as non-expiring. iOS matches.
        guard let exp = payload["exp"] else { return true }

        let expirySeconds: TimeInterval
        if let intExp = exp as? Int {
            expirySeconds = TimeInterval(intExp)
        } else if let dblExp = exp as? Double {
            expirySeconds = dblExp
        } else {
            // `exp` present but malformed — treat as invalid.
            return false
        }

        let expiryDate = Date(timeIntervalSince1970: expirySeconds)
        return expiryDate.addingTimeInterval(clockSkewSeconds) > now
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to multiple of 4 for Data(base64Encoded:).
        let pad = (4 - (s.count % 4)) % 4
        s.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: s)
    }
}
