// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Tests the public, gated voice-call surface. Voice calling ships without an
/// on-device media engine, so the public entry points must report
/// `.voice(.notImplemented)` — never silently no-op or appear to connect.
final class PolyCallTests: XCTestCase {

    private let config = Configuration(apiKey: "test_api_key", environment: .us)

    func test_start_throwsNotImplemented() async {
        let call = PolyMessaging.voice(config)
        XCTAssertEqual(call.state, .idle)

        do {
            try await call.start()
            XCTFail("voice calling is gated — start() must throw")
        } catch {
            XCTAssertEqual(error as? PolyError, .voice(.notImplemented))
        }
        XCTAssertEqual(call.state, .failed(.voice(.notImplemented)))
    }

    func test_states_replaysGatedFailure() async {
        let call = PolyMessaging.voice(config)
        try? await call.start()

        // The state stream replays the current value to late subscribers.
        var received: CallState?
        for await state in call.states {
            received = state
            break
        }
        XCTAssertEqual(received, .failed(.voice(.notImplemented)))
    }

    func test_end_isSafeOnGatedCall() async {
        let call = PolyMessaging.voice(config)
        await call.end()
        XCTAssertEqual(call.state, .ended)
    }

    func test_setMuted_isSafeOnGatedCall() async {
        // No media engine, but mute must not crash.
        let call = PolyMessaging.voice(config)
        await call.setMuted(true)
    }
}
