# Changelog

All notable changes to the PolyMessaging iOS SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org). While the SDK
is pre-1.0, breaking changes bump the **minor** version.

## [0.2.2] - 2026-05-22

### Changed
- Removed the `POLY_CONNECTOR_TOKEN` environment-variable lookup added in 0.2.1.
  The example apps now inline the `YOUR_CONNECTOR_TOKEN` placeholder in their single
  `initialize(...)` call — swap in your own connector token before running. The live
  probe tests read their token from `POLY_LIVE_TOKEN` / `POLY_LIVE_VOICE_TOKEN` instead.
- `User-Agent` is now `PolyMessaging-iOS/0.2.2`.

### Fixed
- Examples (UIKit): an agent message carrying both an image attachment and response
  suggestions (e.g. the greeting) drew the image carousel **on top of** the suggestion
  pills / following messages. `MessageCell` set the carousel's `isHidden` directly *and*
  the carousel's own `configure(with:)` set it again in the same layout pass; setting an
  arranged subview's `isHidden` to the same value twice corrupts `UIStackView`'s hidden
  bookkeeping, so the later un-hide silently no-opped, the carousel stayed collapsed, the
  cell self-sized to its text only, and the 140pt image card spilled over the rows below.
  Fixed across every UIKit level with attachments (03–07) and `Examples/Components/UIKit`:
  the carousel's `configure(with:)` now owns its `isHidden` with a guarded (change-only)
  write, and the cells no longer toggle it directly.
- Examples: the message composer is now always available in a live conversation,
  regardless of connection state. It previously gated the input/send controls on
  `session.isReady` (which flips `false` on any socket drop) and, in 06/07, additionally
  on the terminal `failureReason` — so going offline (or exhausting the reconnect budget)
  made it impossible to write or send. Sending is optimistic (the SDK queues and tracks
  delivery: pending → failed → retry), so the composer is now gated **only** on `hasEnded`
  across every level and both frameworks; offline, reconnecting, and terminally-failed
  states all keep it usable.

## [0.2.1] - 2026-05-22

### Changed
- Examples and quick-start templates no longer hardcode a connector token. They read
  `POLY_CONNECTOR_TOKEN` from the environment and fall back to a `YOUR_CONNECTOR_TOKEN`
  placeholder, so no credential ships in source.
- `User-Agent` is now `PolyMessaging-iOS/0.2.1`.

## [0.2.0] - 2026-05-22

### Removed (breaking)
- Removed the signed-identity / custom-metadata `Configuration` fields
  (`externalUserId`, `userSignature`, `context`, `contextSignature`,
  `customMetadata`). The backend's create-session endpoint never consumed them
  (it reads only `streaming_enabled`), so they had no effect. If you set any of
  these, delete them — the rest of `Configuration` is unchanged.

### Changed
- `User-Agent` is now `PolyMessaging-iOS/0.2.0`.

## [0.1.0] - 2026-05-21

- Initial release: fully managed chat over the PolyAI Messaging API — token
  auth, session create/resume, WebSocket lifecycle, heartbeat, reconnection
  with cursor-based replay, streaming chunk reassembly, optimistic send with
  delivery tracking, and live-agent handoff, exposed through a SwiftUI/UIKit
  bindable `ChatSession`. Dependency-free; iOS 15+ / macOS 12+.
