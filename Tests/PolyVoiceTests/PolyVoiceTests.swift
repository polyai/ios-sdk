// Copyright PolyAI Limited

import XCTest
import PolyMessaging
@testable import PolyVoice

/// Tests for the PolyVoice product surface. The WebRTC-backed implementation is
/// iOS-only, so the meat of this suite is `#if os(iOS)` and exercised by the
/// iOS-simulator CI leg (`xcodebuild test`); under `swift test` on macOS it
/// compiles to the options-only subset.
final class PolyVoiceTests: XCTestCase {

    func test_voiceOptions_defaults() {
        let options = VoiceOptions(webrtcToken: "t")
        XCTAssertEqual(options.webrtcToken, "t")
        XCTAssertTrue(options.speakerphone, "hands-free is the default for a voice agent")
        XCTAssertNil(options.signalingHost)
    }

    #if os(iOS)
    func test_call_emptyApiKey_throws() {
        XCTAssertThrowsError(try PolyVoice.call(
            config: Configuration(apiKey: ""),
            options: VoiceOptions(webrtcToken: "t")
        )) { error in
            guard case PolyError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
    }

    func test_call_emptyWebrtcToken_throws() {
        XCTAssertThrowsError(try PolyVoice.call(
            config: Configuration(apiKey: "k"),
            options: VoiceOptions(webrtcToken: "")
        ))
    }

    func test_call_customEnvironmentWithoutSignalingHost_throws() {
        let custom = Configuration(
            apiKey: "k",
            environment: .custom(
                restBaseURL: URL(string: "https://gw.example/api/v1")!,
                wsBaseURL: URL(string: "wss://gw.example/ws")!
            )
        )
        XCTAssertThrowsError(try PolyVoice.call(config: custom, options: VoiceOptions(webrtcToken: "t")))
    }

    func test_call_buildsIdleCall_withRealEngine() throws {
        // Wires the REAL WebRTC media engine + audio controller (construction only —
        // nothing touches the peer factory or audio session until start()).
        let call = try PolyVoice.call(
            config: Configuration(apiKey: "k"),
            options: VoiceOptions(webrtcToken: "t")
        )
        XCTAssertEqual(call.state, .idle)
        XCTAssertFalse(call.state.isActive)
    }
    #endif
}
