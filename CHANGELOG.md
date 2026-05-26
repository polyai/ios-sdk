# Changelog

All notable changes to the PolyMessaging iOS SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org). While the SDK
is pre-1.0, breaking changes bump the **minor** version.

## [0.5.0](https://github.com/PolyAI-LDN/poly_messaging_ios/compare/v0.4.0...v0.5.0) (2026-05-26)


### ⚠ BREAKING CHANGES

* rename Configuration.connectorToken to apiKey
* rename Configuration.connectorToken to apiKey
* complete the connector-token → api-key rename
* `Configuration.connectorToken` is renamed to `Configuration.apiKey`. Callers must update their `Configuration.init` arguments:

### Features

* complete the connector-token → api-key rename ([587d7dc](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/587d7dce53336bf19ca805021affba627f02eb35))
* rename Configuration.connectorToken to apiKey ([da30d4b](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/da30d4bfa048fc7f4d9024a3dbe27bfbfcfaf2d4))
* rename Configuration.connectorToken to apiKey ([da30d4b](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/da30d4bfa048fc7f4d9024a3dbe27bfbfcfaf2d4))
* rename Configuration.connectorToken to apiKey ([4e5c634](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/4e5c634bad430719cfce70ecd77c85921efdead6))

## [0.4.0](https://github.com/PolyAI-LDN/poly_messaging_ios/compare/v0.3.0...v0.4.0) (2026-05-26)


### Features

* human-readable PolyError descriptions ([aa79da2](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/aa79da29261bd162d1b1000e3c5bc2f0aeda7e79))
* human-readable PolyError descriptions ([aa79da2](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/aa79da29261bd162d1b1000e3c5bc2f0aeda7e79))

## [0.3.0](https://github.com/PolyAI-LDN/poly_messaging_ios/compare/0.2.2...v0.3.0) (2026-05-26)


### ⚠ BREAKING CHANGES

* drop greetingMessage (backend always overrides it)
* one streamingEnabled switch; rewrite root README for headless framing

### Features

* **01-Hello:** auto-scroll as the agent streams ([2e03636](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/2e036369b7da0f975fee11f8f9474e9a0d73f83c))
* drop greetingMessage (backend always overrides it) ([252709a](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/252709af831ae6868ec52c2e9157c6eeec405b22))
* one streamingEnabled switch; rewrite root README for headless framing ([1ad590c](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/1ad590ce632d167551561b5631fe7a912bf02675))
* surface invalid connector token via ChatSession.failureReason ([2989862](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/29898628efbd8dd879fe478b81a41642e848c25c))
* surface invalid connector token via ChatSession.failureReason ([2989862](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/29898628efbd8dd879fe478b81a41642e848c25c))
* surface invalid connector token via ChatSession.failureReason ([2910849](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/29108497a17626e7b54493546b9c946588425751))


### Bug Fixes

* align session timeout and max-message-size defaults with backend ([17c515e](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/17c515e979d0218dd91f56dc74fd2bc9b1a66476))
* align session timeout and max-message-size defaults with backend ([8efa682](https://github.com/PolyAI-LDN/poly_messaging_ios/commit/8efa6823f02de2c7169428a518e928e542e7a679))

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
  Fixed across every UIKit level with attachments (03–07): the carousel's
  `configure(with:)` now owns its `isHidden` with a guarded (change-only) write, and the
  cells no longer toggle it directly.
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
