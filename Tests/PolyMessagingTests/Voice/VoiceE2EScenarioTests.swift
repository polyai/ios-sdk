// Copyright PolyAI Limited

import XCTest
@_spi(PolyVoice) @testable import PolyMessaging

/// End-to-end *scenario* coverage for voice at the layer the example apps bind
/// to — the public `PolyCall` surface (the voice twin of the chat
/// `E2EScenarioTests`). Each test drives a real
/// `PolyCall → CallCoordinator → VoiceSessionLinker` pipeline over a
/// `MockConnection` + `MockSignalingChannel` + `StubMediaEngine` (no network,
/// no WebRTC stack) and asserts what the app observes: `states`, `state`,
/// `isMuted`, and `audioState`.
@MainActor
final class VoiceE2EScenarioTests: XCTestCase {

    private struct Stack {
        let call: PolyCall
        let api: MockRestApi
        let conn: MockConnection
        let channel: MockSignalingChannel
        let media: StubMediaEngine
    }

    /// Collects every `CallState` the public stream publishes, in order.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [CallState] = []
        var states: [CallState] { lock.lock(); defer { lock.unlock() }; return _states }
        func append(_ state: CallState) { lock.lock(); _states.append(state); lock.unlock() }
    }

    private func makeStack() -> Stack {
        let api = MockRestApi()
        let conn = MockConnection()
        let channel = MockSignalingChannel()
        let media = StubMediaEngine()
        let logger = NoopLogger()
        let linker = VoiceSessionLinker(
            connection: conn,
            wsBaseURL: URL(string: "wss://messaging.test/ws")!,
            logger: logger
        )
        let coordinator = CallCoordinator(
            api: api,
            linker: linker,
            channel: channel,
            media: media,
            authToken: "tok",
            streamingEnabled: true,
            logger: logger,
            disconnectGraceNanos: 300_000_000,
            reconnectBaseNanos: 20_000_000,
            reconnectConnectTimeoutNanos: 400_000_000
        )
        return Stack(call: PolyCall(coordinator: coordinator), api: api, conn: conn, channel: channel, media: media)
    }

    /// `start()` the call and feed SESSION_START so the pipeline arms.
    private func startCall(_ stack: Stack) async throws {
        let task = Task { try await stack.call.start() }
        let connected = await waitUntil { stack.conn.connectCalls.count == 1 }
        XCTAssertTrue(connected, "start() opens the messaging WS via the linker")
        stack.conn.simulateMessage(.sessionStart(makeEnvelope(), makeSessionStartPayload()))
        try await task.value
    }

    /// Drive the armed pipeline to `.connected` (offer → answer → media up).
    private func connect(_ stack: Stack) async {
        stack.channel.emit(.opened)
        _ = await waitUntil { stack.channel.sentFrames(ofType: "offer").count == 1 }
        stack.channel.emit(.message(frame([
            "type": "answer", "sessionId": "sig_1",
            "data": ["type": "answer", "sdp": "v=0-answer"],
        ])))
        _ = await waitUntil { stack.media.acceptedAnswer == "v=0-answer" }
        stack.media.driveState(.connected)
        let connected = await waitUntil { await MainActor.run { stack.call.state == .connected } }
        XCTAssertTrue(connected, "the public state reaches .connected")
    }

    private func frame(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    // MARK: - Scenarios

    /// The example apps' whole UI is a `for await` over `call.states` — the
    /// exact progression they render must hold: connecting → connected → ended.
    func test_fullCall_publishesConnectingConnectedEnded() async throws {
        let stack = makeStack()
        let log = StateLog()
        // Subscribing registers the continuation synchronously, so every state
        // emitted from here on is buffered for the observer below.
        let stream = stack.call.states
        let observer = Task { for await state in stream { log.append(state) } }
        defer { observer.cancel() }

        try await startCall(stack)
        await connect(stack)
        await stack.call.end()

        let ended = await waitUntil { log.states.last == .ended }
        XCTAssertTrue(ended)
        XCTAssertEqual(log.states, [.connecting, .connected, .ended],
                       "the public stream publishes the exact lifecycle the UI renders")
    }

    func test_signalingError_surfacesFailedState() async throws {
        let stack = makeStack()
        try await startCall(stack)
        stack.channel.emit(.opened)
        stack.channel.emit(.message(frame(["type": "error", "data": ["message": "bad token"]])))

        let failed = await waitUntil {
            stack.call.state == .failed(.voice(.signalingFailed("bad token")))
        }
        XCTAssertTrue(failed, "a gateway error reaches the app as .failed")
        XCTAssertFalse(stack.call.state.isActive)
    }

    /// A late subscriber (e.g. a re-presented call screen) must immediately see
    /// the current state, not wait for the next transition.
    func test_lateSubscriber_replaysCurrentState() async throws {
        let stack = makeStack()
        try await startCall(stack)
        await connect(stack)

        var first: CallState?
        for await state in stack.call.states {
            first = state
            break
        }
        XCTAssertEqual(first, .connected, "late subscribers replay the live state")
    }

    func test_muteRoundTrip_reachesEngineAndReadsBack() async throws {
        let stack = makeStack()
        try await startCall(stack)
        await connect(stack)

        await stack.call.setMuted(true)
        XCTAssertEqual(stack.media.muted, true, "mute reaches the media engine")
        var muted = await stack.call.isMuted
        XCTAssertTrue(muted)

        await stack.call.setMuted(false)
        XCTAssertEqual(stack.media.muted, false)
        muted = await stack.call.isMuted
        XCTAssertFalse(muted)
    }

    func test_audioDeviceSelection_andSnapshots_flowThroughPublicSurface() async throws {
        let stack = makeStack()
        try await startCall(stack)
        await connect(stack)

        let speaker = AudioDevice(kind: .speakerphone, name: "Speaker", id: "builtin.speaker")
        await stack.call.setAudioDevice(speaker)
        XCTAssertEqual(stack.media.audioDeviceSelections.first ?? nil, speaker)

        let snapshot = AudioState(availableDevices: [speaker], selectedDevice: speaker)
        let stream = stack.call.audioStates
        stack.media.driveAudioState(snapshot)
        var received: AudioState?
        for await state in stream {
            received = state
            break
        }
        XCTAssertEqual(received, snapshot, "engine audio snapshots reach the app's picker stream")
    }

    /// "Safe to call at any time": ending a call that never started must not
    /// crash or wedge the instance.
    func test_endBeforeStart_isSafe() async throws {
        let stack = makeStack()
        await stack.call.end()
        XCTAssertEqual(stack.call.state, .idle, "no lifecycle was started, so none is published")

        // The instance is still usable afterwards.
        try await startCall(stack)
        XCTAssertEqual(stack.call.state, .connecting)
        await stack.call.end()
        let ended = await waitUntil { await MainActor.run { stack.call.state == .ended } }
        XCTAssertTrue(ended)
    }
}
