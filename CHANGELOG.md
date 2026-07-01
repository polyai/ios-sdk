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
- A SwiftUI + UIKit **Voice** example (tap-to-call).

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
