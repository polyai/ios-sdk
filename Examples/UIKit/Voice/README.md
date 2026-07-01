# Voice (UIKit)

The UIKit counterpart of the SwiftUI Voice example — a one-screen tap-to-call demo on **`PolyVoice`**:
`PolyVoice.call(...)`, observe `call.states`, start / mute / end. Programmatic UI, no storyboard.

## Run it

1. Open `VoiceUIKit.xcodeproj` and set your team under **Signing & Capabilities**.
2. In `CallViewController.swift`, fill in your connector from **Agent Studio › Connector Settings** —
   `apiKey` (connector token) + `VoiceOptions(webrtcToken:)` (a **distinct** token).
3. Select a **physical iPhone** and Run — WebRTC audio needs real hardware (the simulator can't
   carry the media). Allow the microphone, tap **Start call**, and talk.

## What it shows

- `PolyVoice.call(config:options:)` → a `PolyCall`
- `for await state in call.states` driving the label/button on the main actor
- `call.setMuted(_:)` / `call.end()`

`PolyVoice` is a **separate product** from `PolyMessaging`, so chat-only apps never link the WebRTC
binary. Full reference: the [voice guide](../../../docs/PolyVoice.md).
