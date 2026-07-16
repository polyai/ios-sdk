// Copyright PolyAI Limited

import AVFAudio
import CallKit
import PolyMessaging
import PolyVoice

/// Bridges one PolyVoice call to CallKit: the system call UI, lock-screen and
/// AirPods/car controls, phone-call audio priority, and hold/decline arbitration
/// when a cellular call arrives mid-agent-call.
///
/// The CallKit contract this class encodes:
///  - user intents (start / end / mute) are **requested** through `CXCallController`
///    and only executed in the matching `perform` callback — the system may need
///    to arbitrate with other calls first, and the system UI stays in sync
///  - the audio session is **configured** in `perform(CXStartCallAction)` but only
///    ever **activated by the system** — the `didActivate`/`didDeactivate`
///    callbacks forward to `PolyVoice`'s CallKit hooks
///  - remote endings (agent hangs up, failure) are **reported**
///    (`reportCall(endedAt:reason:)`), never requested
final class CallKitController: NSObject, CXProviderDelegate {

    /// Wire these to the `PolyCall` — they run when the system approves each action.
    var performStart: (() -> Void)?
    var performEnd: (() -> Void)?
    var performMute: ((Bool) -> Void)?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var callUUID: UUID?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1          // one agent call at a time —
        config.maximumCallsPerCallGroup = 1   // don't advertise Add Call / swap
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false // keep agent calls out of Phone Recents
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    var hasActiveCall: Bool { callUUID != nil }

    // MARK: - App-side intents (requests, not commands)

    func requestStart(agentName: String) {
        let uuid = UUID()
        callUUID = uuid
        let handle = CXHandle(type: .generic, value: agentName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if error != nil { self?.callUUID = nil } // e.g. calls restricted by Screen Time
        }
    }

    func requestEnd() {
        guard let uuid = callUUID else { return }
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    /// App-UI mute must round-trip through CallKit so the system UI stays in sync;
    /// the actual `setMuted` happens in `perform(CXSetMutedCallAction)`.
    func requestMute(_ muted: Bool) {
        guard let uuid = callUUID else { return }
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { _ in }
    }

    // MARK: - Call-state reporting (drive from `call.states`)

    func reportConnected() {
        guard let uuid = callUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    /// The agent hung up, or the call failed — reported, never requested.
    func reportEnded(failed: Bool) {
        guard let uuid = callUUID else { return }
        callUUID = nil
        provider.reportCall(with: uuid, endedAt: nil, reason: failed ? .failed : .remoteEnded)
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        callUUID = nil
        performEnd?()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Configure (never activate) BEFORE fulfilling: the session must already
        // have its voice-call shape when the system activates it — configuring
        // late (or self-activating) is the classic "didActivate never fires /
        // no audio" CallKit failure.
        PolyVoice.callKitConfigureAudioSession()
        performStart?()
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        performEnd?()
        callUUID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        // Fires for BOTH the app's requestMute and the system call UI's mute button.
        performMute?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        PolyVoice.callKitAudioSessionDidActivate(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        PolyVoice.callKitAudioSessionDidDeactivate(audioSession)
    }
}
