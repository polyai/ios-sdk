import Foundation
import XCTest
@testable import PolyMessaging

// MARK: - Mock signaling channel

/// In-memory `SignalingChannel` with a single-consumer replay buffer: events
/// emitted before the coordinator's loop subscribes are buffered and flushed on
/// subscription, so the pipeline can be driven deterministically without timing
/// races.
final class MockSignalingChannel: SignalingChannel, @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: AsyncStream<SignalingChannelEvent>.Continuation?
    private var buffer: [SignalingChannelEvent] = []

    private(set) var sentFrames: [Data] = []
    private(set) var openCalled = false
    private(set) var closeCalled = false

    var events: AsyncStream<SignalingChannelEvent> {
        AsyncStream { cont in
            lock.lock()
            continuation = cont
            let pending = buffer
            buffer.removeAll()
            lock.unlock()
            for event in pending { cont.yield(event) }
        }
    }

    func open() async {
        lock.lock(); openCalled = true; lock.unlock()
    }

    func send(_ data: Data) async {
        lock.lock(); sentFrames.append(data); lock.unlock()
    }

    func close() async {
        lock.lock(); closeCalled = true; lock.unlock()
    }

    // Test driver
    func emit(_ event: SignalingChannelEvent) {
        lock.lock()
        let cont = continuation
        if cont == nil { buffer.append(event) }
        lock.unlock()
        cont?.yield(event)
    }

    /// Decoded JSON of every frame the coordinator sent.
    func sentJSON() -> [[String: Any]] {
        lock.lock(); let frames = sentFrames; lock.unlock()
        return frames.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func sentFrames(ofType type: String) -> [[String: Any]] {
        sentJSON().filter { ($0["type"] as? String) == type }
    }
}

// MARK: - Stub media engine

/// A `CallMediaEngine` that produces a fixed offer SDP and records every
/// interaction. Lets unit tests drive the pipeline and the live probe supply a
/// real Opus offer — without a real WebRTC stack.
final class StubMediaEngine: CallMediaEngine, @unchecked Sendable {

    let offerSDP: String
    var createOfferError: Error?

    private let lock = NSLock()
    private var _createOfferCount = 0
    private var _acceptedAnswer: String?
    private var _remoteCandidates: [ICECandidate] = []
    private var _muted: Bool?
    private var _closeCount = 0
    private var localHandler: (@Sendable (ICECandidate) -> Void)?
    private var stateHandler: (@Sendable (CallMediaState) -> Void)?

    init(offerSDP: String = StubMediaEngine.minimalOffer) {
        self.offerSDP = offerSDP
    }

    var createOfferCount: Int { lock.lock(); defer { lock.unlock() }; return _createOfferCount }
    var acceptedAnswer: String? { lock.lock(); defer { lock.unlock() }; return _acceptedAnswer }
    var remoteCandidates: [ICECandidate] { lock.lock(); defer { lock.unlock() }; return _remoteCandidates }
    var muted: Bool? { lock.lock(); defer { lock.unlock() }; return _muted }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return _closeCount }

    func createOffer() async throws -> String {
        lock.lock(); _createOfferCount += 1; let err = createOfferError; lock.unlock()
        if let err { throw err }
        return offerSDP
    }

    func acceptAnswer(sdp: String) async throws {
        lock.lock(); _acceptedAnswer = sdp; lock.unlock()
    }

    func addRemoteCandidate(_ candidate: ICECandidate) async throws {
        lock.lock(); _remoteCandidates.append(candidate); lock.unlock()
    }

    func setLocalCandidateHandler(_ handler: @escaping @Sendable (ICECandidate) -> Void) async {
        lock.lock(); localHandler = handler; lock.unlock()
    }

    func setStateHandler(_ handler: @escaping @Sendable (CallMediaState) -> Void) async {
        lock.lock(); stateHandler = handler; lock.unlock()
    }

    func setMuted(_ muted: Bool) async {
        lock.lock(); _muted = muted; lock.unlock()
    }

    func close() async {
        lock.lock(); _closeCount += 1; lock.unlock()
    }

    // Test drivers
    func emitLocalCandidate(_ candidate: ICECandidate) {
        lock.lock(); let h = localHandler; lock.unlock()
        h?(candidate)
    }

    func driveState(_ state: CallMediaState) {
        lock.lock(); let h = stateHandler; lock.unlock()
        h?(state)
    }

    /// A syntactically valid audio (Opus) offer. Enough for the gateway to
    /// produce an `answer` at the signaling layer (no real DTLS follows).
    static let minimalOffer: String = [
        "v=0",
        "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=group:BUNDLE 0",
        "a=msid-semantic: WMS",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "c=IN IP4 0.0.0.0",
        "a=rtcp:9 IN IP4 0.0.0.0",
        "a=ice-ufrag:probe",
        "a=ice-pwd:probepasswordprobepasswordab",
        "a=ice-options:trickle",
        "a=fingerprint:sha-256 " + Array(repeating: "AB", count: 32).joined(separator: ":"),
        "a=setup:actpass",
        "a=mid:0",
        "a=sendrecv",
        "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2",
        "a=fmtp:111 minptime=10;useinbandfec=1",
        "",
    ].joined(separator: "\r\n")
}

// MARK: - Async polling

/// Polls `condition` until true or the timeout elapses. Returns whether it
/// became true.
@discardableResult
func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
