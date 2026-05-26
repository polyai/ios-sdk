// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

final class JWTValidatorTests: XCTestCase {

    // Three-part shape, no exp → valid (web parity: missing exp = non-expiring)
    func testValidJWTWithoutExp() {
        let token = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.e30."
        XCTAssertTrue(JWTValidator.isStructurallyValid(token))
    }

    // exp in the future → valid
    func testValidJWTWithFutureExp() {
        // header.payload.signature where payload is { "exp": 9999999999 }
        let token = "eyJhbGciOiJub25lIn0.eyJleHAiOjk5OTk5OTk5OTl9."
        XCTAssertTrue(JWTValidator.isStructurallyValid(token))
    }

    // exp in the past → invalid
    func testExpiredJWT() {
        let pastExp = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let payloadJSON = "{\"exp\":\(pastExp)}"
        let payloadB64 = Self.base64URLEncode(payloadJSON.data(using: .utf8)!)
        let token = "eyJhbGciOiJub25lIn0.\(payloadB64)."
        XCTAssertFalse(JWTValidator.isStructurallyValid(token))
    }

    // 5s clock-skew window: token expiring 2s ago should still be valid
    func testClockSkewTolerance() {
        let nearPastExp = Int(Date().addingTimeInterval(-2).timeIntervalSince1970)
        let payloadJSON = "{\"exp\":\(nearPastExp)}"
        let payloadB64 = Self.base64URLEncode(payloadJSON.data(using: .utf8)!)
        let token = "eyJhbGciOiJub25lIn0.\(payloadB64)."
        // Within 5s skew → still valid
        XCTAssertTrue(JWTValidator.isStructurallyValid(token))
    }

    // Token with only 2 parts → malformed
    func testTwoPartsRejected() {
        XCTAssertFalse(JWTValidator.isStructurallyValid("header.payload"))
    }

    // Token with non-base64url payload → malformed
    func testMalformedPayloadRejected() {
        XCTAssertFalse(JWTValidator.isStructurallyValid("header.!!!.signature"))
    }

    // Empty token → malformed
    func testEmptyTokenRejected() {
        XCTAssertFalse(JWTValidator.isStructurallyValid(""))
    }

    // Non-JWT string → malformed
    func testNonJWTRejected() {
        XCTAssertFalse(JWTValidator.isStructurallyValid("test_token"))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
