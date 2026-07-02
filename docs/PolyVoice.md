# PolyVoice — WebRTC voice calling

Live, two-way WebRTC voice calls to a PolyAI agent — the companion to
[`PolyMessaging`](../README.md). It ships as a **separate product/pod** so chat-only
apps never link the WebRTC binary, and it reuses the messaging `Configuration` plus
the same `CallState` / `PolyError` vocabulary — no new concepts.

## Install

**Swift Package Manager** — add the package and depend on the `PolyVoice` product:

```swift
.package(url: "https://github.com/polyai/ios-sdk.git", from: "0.9.0")
// target dependency (the package identity is the repo name, `ios-sdk`):
.product(name: "PolyVoice", package: "ios-sdk")
```

`PolyVoice` transitively pulls the WebRTC xcframework; `PolyMessaging` stays
source-only, so a chat-only target depends only on `PolyMessaging`.

**CocoaPods**:

```ruby
pod 'PolyVoice', '~> 0.9.0'   # chat-only apps use `pod 'PolyMessaging'`
```

## Quickstart

```swift
import PolyMessaging
import PolyVoice

let call = try PolyVoice.call(
    config: Configuration(apiKey: "YOUR_API_KEY"),          // connector token — Agent Studio › Connector Settings
    options: VoiceOptions(webrtcToken: "YOUR_WEBRTC_TOKEN")  // WebRTC token — same place, a distinct value
)   // throws PolyError.invalidConfiguration on a blank token or a .custom env without signalingHost

// Observe the lifecycle: .idle → .connecting → .connected → .ended / .failed
Task { for await state in call.states { render(state) } }

try await call.start()   // after the microphone permission is granted
await call.setMuted(true)
await call.end()
```

`CallState`, `PolyError`, and `Configuration` are the same types from `PolyMessaging`.

## Microphone permission

A call needs the microphone. Add **`NSMicrophoneUsageDescription`** to your app's
`Info.plist` (a call without it crashes on iOS). The system prompts on the first
call; the SDK activates the `AVAudioSession` for you.

## Backgrounding

To keep a call running while your app is in the background (the norm for a voice call),
enable the **`audio` background mode** — add `UIBackgroundModes` to your `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

The SDK holds a `playAndRecord` `AVAudioSession`, so with this mode the call keeps running
when the app is backgrounded; without it, iOS suspends the app and the call drops. Both Voice
examples set this. (There's no CallKit integration — a call is a normal app audio session, not
a system phone call.)

## Credentials

A voice call needs **two credentials**, both on your agent in
**[Agent Studio](https://studio.poly.ai) › Connector Settings** (the same connector
you use for chat):

| Value | What it is | Sent as |
|---|---|---|
| **API key** — `Configuration.apiKey` | your connector token | `X-Token` (authenticates the call) |
| **WebRTC token** — `VoiceOptions.webrtcToken` | the gateway auth token — a **distinct** token from the API key | the offer `authToken` + ICE-servers fetch |

> **Region:** calls default to the US gateway. For a UK / EUW / other-region (or dev) agent, set the
> environment on the shared `Configuration` — e.g. `Configuration(apiKey: …, environment: .cluster("…"))`,
> the same `Configuration` you use for chat. See the [messaging guide](../README.md#configuration).
>
> **Custom / self-hosted gateway:** pass `VoiceOptions(webrtcToken:, signalingHost:)` to point at a specific
> gateway host (required when the environment is `.custom`).

## Audio routing

The call is **accessory-aware** by default: a connected wired/Bluetooth headset is
used automatically; otherwise it falls back to the loudspeaker (hands-free — set
`VoiceOptions(speakerphone: false)` to fall back to the receiver instead).

## Resilience

- **Connectivity:** STUN/TURN servers are fetched from the gateway per call, so calls connect
  behind symmetric NAT / CGNAT (falls back to public STUN if the fetch fails).
- **Reconnect:** a dropped signaling socket reconnects automatically (backoff 1s / 2s / 4s) on
  the same session and re-flushes buffered ICE before the call is failed.
- **Interruptions:** an incoming phone call or Siri mutes the mic and restores it; a
  non-resumable interruption ends the call as `PolyError.voice(.interrupted)`.
- **Errors:** a post-connect drop surfaces as `PolyError.voice(.disconnected)`. Both it and
  `.interrupted` are `isRetryable`, so you can offer a one-tap retry.

## Architecture

`PolyVoice` provides a real `CallMediaEngine` (an `RTCPeerConnection` audio engine)
and an `AVAudioSession` controller, injected into the existing `PolyMessaging`
`CallCoordinator` via `PolyCall.wired(config:webrtcToken:mediaEngine:)`. The
signaling pipeline (auth → session → link → signaling → offer/answer/ICE) lives in
`PolyMessaging` and is exercised end-to-end by its test suite.

---

**Example:** a one-screen tap-to-call demo in both toolkits —
[`Examples/SwiftUI/Voice`](../Examples/SwiftUI/Voice) ·
[`Examples/UIKit/Voice`](../Examples/UIKit/Voice). Drop your connector token +
WebRTC token into the `PolyVoice.call(...)` block and run.
