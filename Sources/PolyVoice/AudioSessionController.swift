// Copyright PolyAI Limited

#if os(iOS)
import Foundation
import AVFoundation
import WebRTC
import PolyMessaging

/// Configures the audio session for a live call — the iOS analog of Android's
/// `AndroidAudioControl`. Accessory-aware: a connected headset/Bluetooth is used
/// automatically; otherwise it falls back to the loudspeaker (hands-free — the
/// natural mode for a voice agent) when `defaultToSpeaker` is true.
final class AudioSessionController: @unchecked Sendable {

    private let defaultToSpeaker: Bool
    private let session = RTCAudioSession.sharedInstance()
    // Guards deactivate(): never touch the process-global audio session on a call that never
    // activated it (e.g. start() failed before createOffer) — mirrors Android's `activated` guard.
    private var activated = false

    /// Sink for audio-session interruptions (phone call / Siri / another app), set by the engine.
    var onInterruption: (@Sendable (CallInterruption) -> Void)?
    private var interruptionObserver: NSObjectProtocol?

    init(defaultToSpeaker: Bool) {
        self.defaultToSpeaker = defaultToSpeaker
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in self?.handleInterruption(note) }
    }

    deinit {
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
    }

    /// Map an `AVAudioSession` interruption to the call's interruption vocabulary: a begin
    /// mutes the mic; an end resumes if the system allows, otherwise ends the call.
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onInterruption?(.began)
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            onInterruption?(options.contains(.shouldResume) ? .endedResume : .endedStop)
        @unknown default:
            break
        }
    }

    func activate() {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        activated = true
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        do {
            try session.setConfiguration(config, active: true)
            // Accessory-aware default: only force the loudspeaker when nothing is plugged in.
            if defaultToSpeaker && !hasExternalOutput() {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            // Best-effort — WebRTC falls back to its own audio configuration.
        }
    }

    func deactivate() {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        guard activated else { return } // nothing was acquired — don't clobber the host app's audio
        activated = false
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(false)
    }

    /// True when a wired or Bluetooth output is currently connected.
    private func hasExternalOutput() -> Bool {
        let external: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .carAudio,
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { external.contains($0.portType) }
    }
}
#endif
