// FUTURE: tests for the disabled certificate-pinning helper. Re-enable when
// CertificatePinner.swift is revived (see notes there).
#if false
import XCTest
@testable import PolyMessaging

final class CertificatePinnerTests: XCTestCase {

    // MARK: - Configuration plumbing

    func testDefaultPinningIsNone() throws {
        let client = try PolyMessaging.configure(connectorToken: "ct_test_abc")
        XCTAssertEqual(client.config.certificatePinning, .none)
    }

    func testCustomSPKIPinningPropagatesToConfig() throws {
        let hash = Data(repeating: 0xAB, count: 32)
        let config = Configuration(
            connectorToken: "ct_test_abc",
            certificatePinning: .spki(sha256Hashes: [hash])
        )
        let client = try PolyMessaging.configure(config)
        guard case .spki(let hashes) = client.config.certificatePinning else {
            XCTFail("Expected .spki, got \(client.config.certificatePinning)")
            return
        }
        XCTAssertEqual(hashes, [hash])
    }

    func testCustomCertificatePinningPropagatesToConfig() throws {
        let hash = Data(repeating: 0xCD, count: 32)
        let config = Configuration(
            connectorToken: "ct_test_abc",
            certificatePinning: .certificate(sha256Hashes: [hash])
        )
        let client = try PolyMessaging.configure(config)
        guard case .certificate(let hashes) = client.config.certificatePinning else {
            XCTFail("Expected .certificate, got \(client.config.certificatePinning)")
            return
        }
        XCTAssertEqual(hashes, [hash])
    }

    // MARK: - Equatable

    func testEquatableCases() {
        let h1 = Data(repeating: 0x01, count: 32)
        let h2 = Data(repeating: 0x02, count: 32)

        XCTAssertEqual(CertificatePinning.none, CertificatePinning.none)
        XCTAssertEqual(CertificatePinning.spki(sha256Hashes: [h1]),
                       CertificatePinning.spki(sha256Hashes: [h1]))
        XCTAssertNotEqual(CertificatePinning.spki(sha256Hashes: [h1]),
                          CertificatePinning.spki(sha256Hashes: [h2]))
        XCTAssertNotEqual(CertificatePinning.spki(sha256Hashes: [h1]),
                          CertificatePinning.certificate(sha256Hashes: [h1]))
    }

    // MARK: - URLSession factory

    func testPinnedURLSessionFactoryReturnsSharedForNone() {
        let logger = SilentLogger()
        let session = URLSession.poly_pinned(pinning: .none, logger: logger)
        XCTAssertTrue(session === URLSession.shared,
                      ".none should reuse URLSession.shared")
    }

    func testPinnedURLSessionFactoryBuildsCustomSessionWhenPinned() {
        let logger = SilentLogger()
        let hash = Data(repeating: 0xAB, count: 32)
        let session = URLSession.poly_pinned(
            pinning: .spki(sha256Hashes: [hash]),
            logger: logger
        )
        XCTAssertFalse(session === URLSession.shared,
                       "Pinned mode must use a custom session, not .shared")
        XCTAssertNotNil(session.delegate, "Pinned session must have a delegate")
        XCTAssertTrue(session.delegate is PinningURLSessionDelegate,
                      "Pinned session delegate must be PinningURLSessionDelegate")
        session.invalidateAndCancel()
    }

    // MARK: - Pinner handling — non-server-trust challenges

    func testNonServerTrustChallengeFallsThrough() {
        let pinner = CertificatePinner(
            mode: .spki(sha256Hashes: [Data(repeating: 0xAB, count: 32)]),
            logger: SilentLogger()
        )
        let challenge = makeBasicAuthChallenge()

        let exp = expectation(description: "completion called")
        pinner.handle(challenge: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .performDefaultHandling,
                           "Non-server-trust challenges must not be intercepted")
            XCTAssertNil(credential)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testNoneModeFallsThrough() {
        let pinner = CertificatePinner(mode: .none, logger: SilentLogger())
        let challenge = makeBasicAuthChallenge()

        let exp = expectation(description: "completion called")
        pinner.handle(challenge: challenge) { disposition, _ in
            XCTAssertEqual(disposition, .performDefaultHandling)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Helpers

    private func makeBasicAuthChallenge() -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: "example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoopChallengeSender()
        )
    }
}

private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class SilentLogger: PolyLogger, @unchecked Sendable {
    func debug(_ message: String, metadata: [String: any Sendable]?) {}
    func info(_ message: String, metadata: [String: any Sendable]?) {}
    func warn(_ message: String, metadata: [String: any Sendable]?) {}
    func error(_ message: String, metadata: [String: any Sendable]?) {}
}
#endif
