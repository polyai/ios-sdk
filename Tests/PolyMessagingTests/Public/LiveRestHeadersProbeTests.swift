// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// Opt-in live probe asserting the REST session-create body carries the new
/// `device_type` field (web-SDK parity). Skipped unless POLY_CONNECTOR_TOKEN is set.
final class LiveRestHeadersProbeTests: XCTestCase {

    final class CapturingLogger: PolyLogger, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lines: [String] = []
        private func record(_ level: String, _ message: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append("[\(level)] \(message)")
        }
        func debug(_ message: String, metadata: [String: any Sendable]?) { record("debug", message) }
        func info(_ message: String, metadata: [String: any Sendable]?) { record("info", message) }
        func warn(_ message: String, metadata: [String: any Sendable]?) { record("warn", message) }
        func error(_ message: String, metadata: [String: any Sendable]?) { record("error", message) }
    }

    func test_liveSessionCreate_headersBodyResponse() async throws {
        let token = ProcessInfo.processInfo.environment["POLY_CONNECTOR_TOKEN"] ?? ""
        try XCTSkipUnless(!token.isEmpty, "Set POLY_CONNECTOR_TOKEN to run the live REST probe")

        let host = ProcessInfo.processInfo.environment["POLY_HOST_IDENTIFIER"]
            ?? "https://jupiter-api.dev.polyai.app/"
        let urls = EnvironmentURLs(environment: .cluster("dev"))
        let logger = CapturingLogger()
        let api = RestApi(baseURL: urls.restBaseURL, apiKey: token, hostIdentifier: host, logger: logger)

        let tokenResp = try await api.obtainAccessToken()
        XCTAssertFalse(tokenResp.accessToken.isEmpty, "access token should be returned")

        let deviceType = DeviceTypeDetector.detect().rawValue
        let ctx = SessionContext(platform: "ios", deviceType: deviceType, streamingEnabled: true)
        let created = try await api.createSession(context: ctx)
        XCTAssertFalse(created.sessionId.isEmpty, "session_id should be returned")

        func redact(_ s: String) -> String {
            var out = s
            if !token.isEmpty { out = out.replacingOccurrences(of: token, with: "‹connector-token›") }
            if !tokenResp.accessToken.isEmpty {
                out = out.replacingOccurrences(of: tokenResp.accessToken, with: "‹access-token›")
            }
            return out
        }
        print("\n===== LIVE REST PROBE (cluster=dev, host=\(host)) =====")
        print(logger.lines.map(redact).joined(separator: "\n"))
        print("===== device_type sent=\(deviceType)  session_id=\(created.sessionId.prefix(8))… =====\n")

        XCTAssertTrue(
            logger.lines.contains { $0.contains("device_type") },
            "session-create body must include device_type"
        )
        XCTAssertTrue(
            logger.lines.contains { $0.contains("platform") },
            "session-create body must include platform"
        )
        XCTAssertTrue(
            logger.lines.contains { $0.lowercased().contains("authorization") },
            "session-create must send an Authorization header"
        )
        XCTAssertTrue(
            logger.lines.contains { $0.contains("← 2") },
            "both endpoints should return a 2xx response"
        )
    }
}
