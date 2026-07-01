// Copyright PolyAI Limited

#if os(iOS)
import Foundation
import AVFoundation
import WebRTC

/// Configures the audio session for a live call — the iOS analog of Android's
/// `AndroidAudioControl`. Accessory-aware: a connected headset/Bluetooth is used
/// automatically; otherwise it falls back to the loudspeaker (hands-free — the
/// natural mode for a voice agent) when `defaultToSpeaker` is true.
final class AudioSessionController: @unchecked Sendable {

    private let defaultToSpeaker: Bool
    private let session = RTCAudioSession.sharedInstance()

    init(defaultToSpeaker: Bool) {
        self.defaultToSpeaker = defaultToSpeaker
    }

    func activate() {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
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
