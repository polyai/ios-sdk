// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Opt-in live integration probe: runs the **real** voice-call signaling
/// pipeline against the dev backend and asserts the gateway returns an SDP
/// answer. This is the end-to-end proof that the pure-Swift pipeline (auth →
/// session → messaging-WS link → signaling-WS offer → answer) actually works.
///
/// Skipped by default (it hits the network). Run with:
///
///     POLY_LIVE_VOICE=1 swift test --filter LiveSignalingProbeTests
///
/// A real DTLS/media handshake never follows (there's no media engine), but the
/// gateway answers at the signaling layer regardless, so the round-trip is a
/// faithful check of everything except the on-device audio.
final class LiveSignalingProbeTests: XCTestCase {

    /// API key for the live probe. Supply it via the `POLY_LIVE_VOICE_TOKEN`
    /// environment variable when running; defaults to empty otherwise.
    private let devToken = ""

    func test_liveGateway_returnsSdpAnswer() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POLY_LIVE_VOICE"] == "1",
            "Set POLY_LIVE_VOICE=1 to run the live gateway probe"
        )

        let token = ProcessInfo.processInfo.environment["POLY_LIVE_VOICE_TOKEN"] ?? devToken
        let logger = OSLogLogger(level: .error)
        let urls = EnvironmentURLs(environment: .us)

        let api = RestApi(
            baseURL: urls.restBaseURL,
            apiKey: token,
            hostIdentifier: Bundle.main.bundleIdentifier ?? "",
            logger: logger
        )
        let linker = VoiceSessionLinker(
            connection: WebSocketTransport(logger: logger),
            wsBaseURL: urls.wsBaseURL,
            logger: logger
        )
        let channel = GatewaySignalingChannel(
            url: VoiceEnvironment(environment: .us).signalingURL,
            logger: logger
        )
        let media = StubMediaEngine()  // supplies a valid Opus offer SDP
        let coord = CallCoordinator(
            api: api,
            linker: linker,
            channel: channel,
            media: media,
            authToken: token,
            streamingEnabled: true,
            logger: logger
        )

        try await coord.start()
        let gotAnswer = await waitUntil(timeout: 25) { media.acceptedAnswer != nil }
        await coord.end()

        XCTAssertTrue(gotAnswer, "the live gateway should return an SDP answer")
        XCTAssertTrue(media.acceptedAnswer?.contains("v=0") ?? false,
                      "the answer should be a real SDP body")
    }
}
