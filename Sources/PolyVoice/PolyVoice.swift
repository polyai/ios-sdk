// Copyright PolyAI Limited

import Foundation
import PolyMessaging

/// Entry point for WebRTC voice calling — the PolyVoice companion to PolyMessaging.
///
/// Ships as a **separate** product so chat-only apps never link the WebRTC binary,
/// mirroring Android's separate `ai.poly:voice` artifact. It reuses the messaging
/// `Configuration` and the same `CallState` / `PolyError` vocabulary.
///
/// ```swift
/// let call = try PolyVoice.call(
///     config: Configuration(apiKey: "…"),
///     options: VoiceOptions(webrtcToken: "…")
/// )
/// for await state in call.states { /* .connecting → .connected → … */ }
/// try await call.start()   // after the microphone permission is granted
/// ```
public enum PolyVoice {

    #if os(iOS)
    /// Build a `PolyCall` backed by the real WebRTC audio engine. Does not start
    /// it — observe `PolyCall.states` and call `PolyCall.start()`.
    ///
    /// - Parameters:
    ///   - config: the shared messaging `Configuration` (api key, environment, host).
    ///   - options: voice options — `VoiceOptions.webrtcToken` is required.
    /// - Throws: `PolyError.invalidConfiguration` if `apiKey`/`webrtcToken` is empty, or the
    ///   environment is `.custom` without `VoiceOptions.signalingHost`.
    public static func call(config: Configuration, options: VoiceOptions) throws -> PolyCall {
        guard !config.apiKey.isEmpty else {
            throw PolyError.invalidConfiguration("Configuration.apiKey must not be empty")
        }
        guard !options.webrtcToken.isEmpty else {
            throw PolyError.invalidConfiguration("VoiceOptions.webrtcToken must not be empty")
        }
        let audio = AudioSessionController(defaultToSpeaker: options.speakerphone)
        let engine = WebRTCCallMediaEngine(audio: audio)
        return try PolyCall.wired(
            config: config,
            webrtcToken: options.webrtcToken,
            signalingHost: options.signalingHost,
            mediaEngine: engine
        )
    }
    #endif
}
