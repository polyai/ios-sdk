# Changelog

All notable changes to the PolyMessaging iOS SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org). While the SDK
is pre-1.0, breaking changes bump the **minor** version.

## [0.9.0] - 2026-07-01

Adds **PolyVoice** — live, two-way WebRTC voice calls to a PolyAI agent — as a
**separate product/pod**, so chat-only apps never link the WebRTC binary (mirrors
Android's `ai.poly:voice`). It supplies a real `RTCPeerConnection` audio engine +
`AVAudioSession` control behind the existing, already-tested `CallCoordinator`
signaling pipeline.

### Added
- **`PolyVoice.call(config:options:)`** → a `PolyCall` backed by a real WebRTC audio
  engine (audio-only Opus, offer / answer / trickle ICE, mute). `VoiceOptions.webrtcToken`
  is required — a distinct token from the API key.
- Public media seam on `PolyMessaging`: `CallMediaEngine` / `CallMediaState` /
  `ICECandidate` are now public, plus `PolyCall.wired(config:webrtcToken:mediaEngine:)` —
  so `PolyVoice` injects the WebRTC engine while `PolyMessaging` stays source-only.
- **Gateway ICE/TURN**: the call fetches STUN/TURN servers from the gateway per call, so it
  connects behind symmetric NAT / CGNAT (falls back to public STUN if the fetch fails).
- **Signaling auto-reconnect**: an unexpected signaling-socket drop reconnects with backoff
  (1s / 2s / 4s) on the same session and re-flushes buffered ICE, instead of failing on the
  first blip.
- **Audio-session interruptions**: an incoming phone call / Siri mutes the mic and restores
  it, or ends the call cleanly when the system won't let it resume.
- **`PolyError.Voice.disconnected` / `.interrupted`** (both `isRetryable`); a post-connect
  media drop now surfaces as the retryable `.disconnected` rather than `.mediaFailed`.
- **`VoiceOptions.signalingHost`** for a custom / self-hosted gateway. `PolyVoice.call(config:options:)`
  now `throws` — it validates inputs and reports `PolyError.invalidConfiguration` on a blank
  `apiKey`/`webrtcToken` or a `.custom` environment without a `signalingHost`.
- Mid-call audio **re-routing**: connecting/removing a headset or Bluetooth during a call now
  follows the route instead of staying stuck on the speaker.
- **Audio-output observation + control**: `PolyCall.audioState` (available outputs + the active one),
  `setAudioDevice(_:)` (speaker ↔ earpiece; accessories are system-routed), and `isMuted`.
- A SwiftUI + UIKit **Voice** example (tap-to-call, with mute + a speaker toggle).

## [0.8.0] - 2026-06-04

Add a `device_type` dimension (`mobile` / `tablet` / `desktop`) sent on session
create so analytics can segment traffic by form factor. It is detected
automatically from the device idiom (iPhone → mobile, iPad → tablet, Mac →
desktop) and is orthogonal to `platform` (`ios`), not a replacement. No action
required by integrators; no breaking changes.

## [0.7.0] - 2026-06-01

Add CocoaPods as a distribution channel. The SDK can now be installed with
`pod 'PolyMessaging', '~> 0.7'` alongside the existing Swift Package Manager
options. No API or behaviour changes.

## [0.6.0] - 2026-05-29

**Breaking change.** `Configuration.environment` now defaults to `.us` (US
production) instead of requiring an explicit value, and named production regions
were added — `.us`, `.uk`, `.euw` — alongside the existing `.cluster(_:)` and
`.custom(...)` cases. Apps relying on the previous behaviour should set
`environment:` explicitly to keep pointing at the same backend.

## [0.5.1] - 2026-05-28

Initial public release: fully managed chat over the PolyAI Messaging API — token
auth, session create/resume, WebSocket lifecycle, heartbeat, reconnection
with cursor-based replay, streaming chunk reassembly, optimistic send with
delivery tracking, and live-agent handoff, exposed through a SwiftUI/UIKit
bindable `ChatSession`. Dependency-free; iOS 15+ / macOS 12+.
