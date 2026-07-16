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
        XCTAssertFalse(options.callKit, "CallKit integration is strictly opt-in")
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

    func test_call_callKitMode_buildsIdleCall() throws {
        let call = try PolyVoice.call(
            config: Configuration(apiKey: "k"),
            options: VoiceOptions(webrtcToken: "t", callKit: true)
        )
        XCTAssertEqual(call.state, .idle)
    }
    #endif
}

// MARK: - CallKit audio seam (iOS-only; exercised by the simulator CI leg)

#if os(iOS)
import WebRTC

/// Tests the manual-audio contract behind `VoiceOptions.callKit` against the real
/// process-global `RTCAudioSession`. Serialized within the class because the
/// session IS global state.
final class CallKitAudioSeamTests: XCTestCase {

    override func tearDown() {
        // Leave the global session the way non-CallKit code expects it.
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        session.useManualAudio = false
        super.tearDown()
    }

    func test_configureAudioSession_armsManualAudio_withoutEnabling() {
        PolyVoice.callKitConfigureAudioSession()
        let session = RTCAudioSession.sharedInstance()
        XCTAssertTrue(session.useManualAudio, "CallKit mode must stop WebRTC auto-starting the audio unit")
        XCTAssertFalse(session.isAudioEnabled, "audio stays gated until the system activates the session")
    }

    func test_activateHook_enablesAudio_deactivateHook_disablesIt() {
        PolyVoice.callKitConfigureAudioSession()
        let session = RTCAudioSession.sharedInstance()

        PolyVoice.callKitAudioSessionDidActivate(AVAudioSession.sharedInstance())
        XCTAssertTrue(session.isAudioEnabled, "didActivate releases the audio unit")

        PolyVoice.callKitAudioSessionDidDeactivate(AVAudioSession.sharedInstance())
        XCTAssertFalse(session.isAudioEnabled, "didDeactivate stops the audio unit")
    }

    func test_createOffer_callKitMode_armsManualAudio_andStillProducesSDP() async throws {
        let audio = AudioSessionController(defaultToSpeaker: true, callKitMode: true)
        let engine = WebRTCCallMediaEngine(audio: audio)
        let sdp = try await engine.createOffer(iceServers: [])
        XCTAssertTrue(sdp.contains("m=audio"), "a real audio offer is produced")
        XCTAssertTrue(RTCAudioSession.sharedInstance().useManualAudio,
                      "the engine arms manual audio before the first track exists")
        XCTAssertFalse(RTCAudioSession.sharedInstance().isAudioEnabled)
        await engine.close()
    }

    func test_createOffer_defaultMode_resetsManualAudio() async throws {
        // A leftover manual flag from a previous CallKit call must not silence
        // a subsequent plain call.
        RTCAudioSession.sharedInstance().useManualAudio = true

        let audio = AudioSessionController(defaultToSpeaker: true, callKitMode: false)
        let engine = WebRTCCallMediaEngine(audio: audio)
        _ = try await engine.createOffer(iceServers: [])
        XCTAssertFalse(RTCAudioSession.sharedInstance().useManualAudio,
                       "a non-CallKit call resets the process-global manual-audio flag")
        await engine.close()
    }
}
#endif
