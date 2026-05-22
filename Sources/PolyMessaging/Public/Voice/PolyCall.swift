import Foundation

/// Lifecycle state of a voice call.
public enum CallState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case ended
    case failed(PolyError)
}

public extension CallState {
    var isActive: Bool {
        switch self {
        case .connecting, .connected: return true
        default: return false
        }
    }
}

/// A voice call.
///
/// Created via ``PolyMessagingClient/voice()`` or ``PolyMessaging/voice()``.
/// Voice calling is not yet available in the shipped SDK: there is no bundled
/// media (WebRTC audio) engine, so ``start()`` surfaces
/// `PolyError.voice(.notImplemented)`. The signaling pipeline behind it is
/// fully implemented and exercised end-to-end in the test suite; only the
/// on-device audio engine is outstanding.
public final class PolyCall: @unchecked Sendable {

    private let coordinator: CallCoordinator?
    private let config: Configuration?

    private let stateCaster = Multicaster<CallState>(replayLastValue: true)
    private let lock = NSLock()
    private var _state: CallState = .idle
    private var relayTask: Task<Void, Never>?

    /// Current call state.
    public var state: CallState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Call-state transitions. Late subscribers receive the current state.
    public var states: AsyncStream<CallState> { stateCaster.subscribe() }

    /// Public (gated) initializer: no media engine is bundled, so this call
    /// cannot carry audio yet. `start()` reports `.voice(.notImplemented)`.
    init(config: Configuration) {
        self.config = config
        self.coordinator = nil
    }

    /// Internal seam: drive a fully-wired pipeline (used by the test suite and
    /// the opt-in live integration probe with an injected media engine).
    init(coordinator: CallCoordinator) {
        self.config = nil
        self.coordinator = coordinator
        let stream = coordinator.stateStream
        relayTask = Task { [weak self] in
            for await newState in stream { self?.setState(newState) }
        }
    }

    deinit {
        relayTask?.cancel()
    }

    /// Begin the call. Voice calling is not yet available, so for the shipped
    /// SDK this throws `PolyError.voice(.notImplemented)`.
    public func start() async throws {
        guard let coordinator else {
            setState(.failed(.voice(.notImplemented)))
            throw PolyError.voice(.notImplemented)
        }
        try await coordinator.start()
    }

    /// End the call and release resources. Safe to call at any time.
    public func end() async {
        await coordinator?.end()
        if coordinator == nil { setState(.ended) }
    }

    /// Mute or unmute the local microphone.
    public func setMuted(_ muted: Bool) async {
        await coordinator?.setMuted(muted)
    }

    private func setState(_ newState: CallState) {
        lock.lock()
        _state = newState
        lock.unlock()
        stateCaster.emit(newState)
    }
}
