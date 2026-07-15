// Copyright PolyAI Limited

import XCTest
@testable import PolyMessaging

/// Adversarial inputs for the signaling wire layer (the voice twin of the chat
/// `StressMalformedWire` suite). Two invariants:
///  1. `SignalingProtocol.parse` returns nil (never crashes, never misparses)
///     for garbage, type-confused, truncated, oversized, or non-UTF-8 frames.
///  2. A live `CallCoordinator` shrugs off garbage frames on the socket — the
///     call still connects through them and stays connected after them.
final class StressMalformedSignalingTests: XCTestCase {

    // MARK: - Parser hardening

    func test_parse_garbage_returnsNil() {
        let garbage: [Data] = [
            Data(),                                              // empty
            Data([0xFF, 0xFE, 0x00, 0x01]),                      // non-UTF-8 bytes
            Data("not json at all".utf8),                        // plain text
            Data("{".utf8),                                      // truncated JSON
            Data("[]".utf8),                                     // top-level array
            Data("[{\"type\": \"answer\"}]".utf8),               // array-wrapped frame
            Data("{}".utf8),                                     // no type
            Data("null".utf8),                                   // JSON null
            Data("42".utf8),                                     // JSON scalar
            Data("{\"type\": \"unknown-frame\"}".utf8),          // unknown type
            Data("{\"type\": 42}".utf8),                         // type isn't a string
            Data("{\"type\": null}".utf8),                       // type is null
            Data("{\"TYPE\": \"answer\"}".utf8),                 // wrong-case key
        ]
        for (index, data) in garbage.enumerated() {
            XCTAssertNil(SignalingProtocol.parse(data), "garbage frame #\(index) must parse to nil")
        }
    }

    func test_parse_structurallyValidButIncomplete_returnsNil() {
        let incomplete: [[String: Any]] = [
            ["type": "answer"],                                  // no data
            ["type": "answer", "data": [:]],                     // no sdp
            ["type": "answer", "data": ["sdp": 42]],             // sdp isn't a string
            ["type": "answer", "data": "v=0"],                   // data isn't an object
            ["type": "ice-candidate"],                           // no data
            ["type": "ice-candidate", "data": [:]],              // no candidate
            ["type": "ice-candidate", "data": ["candidate": 1]], // candidate isn't a string
        ]
        for (index, obj) in incomplete.enumerated() {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            XCTAssertNil(SignalingProtocol.parse(data), "incomplete frame #\(index) must parse to nil")
        }
    }

    /// Type confusion on *optional* fields must degrade gracefully (field
    /// dropped), not reject the frame or crash.
    func test_parse_typeConfusedOptionalFields_degradeGracefully() throws {
        // A numeric sessionId is dropped; the answer still parses.
        let answer = try JSONSerialization.data(withJSONObject: [
            "type": "answer", "sessionId": 123,
            "data": ["type": "answer", "sdp": "v=0"],
        ])
        XCTAssertEqual(SignalingProtocol.parse(answer), .answer(sessionId: nil, sdp: "v=0"))

        // String sdpMLineIndex / numeric sdpMid are dropped; the candidate survives.
        let ice = try JSONSerialization.data(withJSONObject: [
            "type": "ice-candidate",
            "data": ["candidate": "cand:1", "sdpMid": 0, "sdpMLineIndex": "0"],
        ])
        XCTAssertEqual(
            SignalingProtocol.parse(ice),
            .iceCandidate(ICECandidate(candidate: "cand:1", sdpMid: nil, sdpMLineIndex: nil))
        )

        // An error frame with a non-string message falls back to the default.
        let error = try JSONSerialization.data(withJSONObject: [
            "type": "error", "data": ["message": 500],
        ])
        XCTAssertEqual(SignalingProtocol.parse(error), .error(message: "Connection failed"))
    }

    func test_parse_oversizedAndDeeplyNestedFrames_noCrash() throws {
        // ~1MB of valid JSON under an unknown type: ignored, not choked on.
        let huge = try JSONSerialization.data(withJSONObject: [
            "type": "unknown-bulk",
            "data": String(repeating: "A", count: 1_000_000),
        ])
        XCTAssertNil(SignalingProtocol.parse(huge))

        // 100 levels of nesting inside a known type's payload.
        let nested = Data(
            ("{\"type\": \"answer\", \"data\": " + String(repeating: "{\"d\":", count: 100)
             + "1" + String(repeating: "}", count: 100) + "}").utf8
        )
        XCTAssertNil(SignalingProtocol.parse(nested), "deep nesting without an sdp is rejected, not crashed on")
    }

    // MARK: - Coordinator resilience

    private func makeArmedCoordinator() async throws -> (CallCoordinator, MockSignalingChannel, StubMediaEngine) {
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let logger = NoopLogger()
        let linker = VoiceSessionLinker(
            connection: conn,
            wsBaseURL: URL(string: "wss://messaging.test/ws")!,
            logger: logger
        )
        let coord = CallCoordinator(
            api: MockRestApi(),
            linker: linker,
            channel: channel,
            media: media,
            authToken: "tok",
            streamingEnabled: true,
            logger: logger
        )
        let startTask = Task { try await coord.start() }
        _ = await waitUntil { conn.connectCalls.count == 1 }
        conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await startTask.value
        return (coord, channel, media)
    }

    func test_coordinator_connectsThroughGarbageFrames() async throws {
        let (coord, channel, media) = try await makeArmedCoordinator()
        channel.emit(.opened)

        // A hostile burst before the answer…
        for i in 0..<25 {
            channel.emit(.message(Data("garbage #\(i) {".utf8)))
            channel.emit(.message(Data([0xFF, 0x00, UInt8(i)])))
        }
        // …must not prevent the real answer from landing.
        let answer = try JSONSerialization.data(withJSONObject: [
            "type": "answer", "sessionId": "sig_1",
            "data": ["type": "answer", "sdp": "v=0-answer"],
        ])
        channel.emit(.message(answer))
        let applied = await waitUntil { media.acceptedAnswer == "v=0-answer" }
        XCTAssertTrue(applied, "the answer is applied despite the garbage burst")

        media.driveState(.connected)
        let connected = await waitUntil { await coord.state == .connected }
        XCTAssertTrue(connected)

        // Garbage after connect must not disturb the live call either.
        for i in 0..<25 {
            channel.emit(.message(Data("post-connect junk \(i)".utf8)))
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let state = await coord.state
        XCTAssertEqual(state, .connected, "a connected call shrugs off garbage frames")
    }
}
