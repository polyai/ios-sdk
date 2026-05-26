import XCTest
@testable import PolyMessaging

final class PolyErrorDescriptionTests: XCTestCase {

    /// Every case must produce a non-empty, user-facing string that does NOT
    /// leak the auto-synthesized struct dump ("PolyMessaging.PolyError…").
    /// One per top-level case category — payload variants are smoke-tested
    /// for two-of-each-kind to catch obvious typos.
    private static let allCases: [PolyError] = [
        .auth(.tokenAcquisitionFailed),
        .auth(.unauthorized),
        .session(.sessionCreationFailed(.unknown)),
        .session(.unexpectedDisconnect(code: 1006, reason: "test")),
        .session(.unexpectedDisconnect(code: 1006, reason: "")),
        .session(.maxReconnectAttemptsExceeded),
        .session(.sessionExpired),
        .session(.sessionEnded(reason: "user_ended")),
        .session(.sessionEnded(reason: nil)),
        .message(.deliveryFailed(draftId: "abc")),
        .message(.payloadTooLarge(maxBytes: 1_048_576)),
        .transport(.networkError("offline")),
        .transport(.networkError("")),
        .transport(.protocolError(reason: "bad frame")),
        .voice(.notImplemented),
        .voice(.signalingFailed("ICE failed")),
        .voice(.mediaFailed("no microphone")),
        .voice(.timedOut),
        .invalidConfiguration("token empty"),
    ]

    func testDescriptionIsNonEmpty() {
        for error in Self.allCases {
            XCTAssertFalse(error.description.isEmpty,
                           "description must not be empty for \(String(reflecting: error))")
        }
    }

    func testDescriptionDoesNotLeakInternalType() {
        for error in Self.allCases {
            XCTAssertFalse(error.description.contains("PolyMessaging.PolyError"),
                           "user-facing description leaked internal type for \(String(reflecting: error)): \(error.description)")
            XCTAssertFalse(error.description.contains("Optional("),
                           "user-facing description leaked Optional wrapper for \(String(reflecting: error)): \(error.description)")
        }
    }

    func testLocalizedDescriptionMatchesDescription() {
        for error in Self.allCases {
            XCTAssertEqual(error.localizedDescription, error.description,
                           "localizedDescription drifted from description for \(String(reflecting: error))")
        }
    }

    func testReflectingReturnsStructuralForm() {
        // Consumers who want the structural form for logs should use
        // String(reflecting:) — it should carry the case name, not UI prose.
        let reflected = String(reflecting: PolyError.auth(.unauthorized))
        XCTAssertTrue(reflected.contains("auth("),
                      "String(reflecting:) should expose the structural form; got: \(reflected)")
        XCTAssertTrue(reflected.contains("unauthorized"),
                      "String(reflecting:) should name the inner case; got: \(reflected)")
        XCTAssertFalse(reflected.contains("Please contact support"),
                      "String(reflecting:) should NOT contain UI prose; got: \(reflected)")
    }

    func testDebugDescriptionPreservesPayloads() {
        let s = String(reflecting: PolyError.session(.unexpectedDisconnect(code: 1006, reason: "boom")))
        XCTAssertTrue(s.contains("1006"), s)
        XCTAssertTrue(s.contains("boom"), s)
        XCTAssertTrue(s.contains("session("), s)
    }

    // Spot-checks of specific user-facing wording so the obvious-looking
    // failures don't get past review by accident.

    func testAuthUnauthorizedWording() {
        let s = PolyError.auth(.unauthorized).description
        XCTAssertTrue(s.contains("token"), s)
        XCTAssertTrue(s.contains("rejected") || s.contains("invalid") || s.contains("Please"), s)
    }

    func testPayloadTooLargeShowsKB() {
        let s = PolyError.message(.payloadTooLarge(maxBytes: 1_048_576)).description
        XCTAssertTrue(s.contains("1024 KB"), "expected human-readable KB; got: \(s)")
    }

    func testUnexpectedDisconnectIncludesCode() {
        let s = PolyError.session(.unexpectedDisconnect(code: 1006, reason: "boom")).description
        XCTAssertTrue(s.contains("1006"), "code should appear; got: \(s)")
        XCTAssertTrue(s.contains("boom"), "reason should appear when present; got: \(s)")
    }

    func testUnexpectedDisconnectOmitsEmptyReason() {
        let s = PolyError.session(.unexpectedDisconnect(code: 1006, reason: "")).description
        XCTAssertFalse(s.hasSuffix(": "), "trailing colon when reason is empty: \(s)")
    }

    func testSessionEndedWithNilReason() {
        let s = PolyError.session(.sessionEnded(reason: nil)).description
        XCTAssertFalse(s.contains("nil"), "nil leaked into user-facing text: \(s)")
        XCTAssertFalse(s.contains("Optional"), "Optional leaked: \(s)")
    }
}
