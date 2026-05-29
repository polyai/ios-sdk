# Changelog

All notable changes to the PolyMessaging iOS SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org). While the SDK
is pre-1.0, breaking changes bump the **minor** version.

## [0.6.0](https://github.com/polyai/ios-sdk/compare/v0.5.1...v0.6.0) (2026-05-29)


### ⚠ BREAKING CHANGES

* `Environment.production` is removed. Replace with `.us` for production US (the previous default URL was `messaging.poly.ai` which is not a real region) or with the appropriate regional case. Most call sites can simply drop the `environment:` argument and pick up the new `.us` default.

### Features

* default Configuration.environment to .us, add named production regions ([#10](https://github.com/polyai/ios-sdk/issues/10)) ([f2c634f](https://github.com/polyai/ios-sdk/commit/f2c634f11fa4c5cf2647a16ec09ac3a88bc6c858))

## [0.5.1] - 2026-05-28

Initial public release: fully managed chat over the PolyAI Messaging API — token
auth, session create/resume, WebSocket lifecycle, heartbeat, reconnection
with cursor-based replay, streaming chunk reassembly, optimistic send with
delivery tracking, and live-agent handoff, exposed through a SwiftUI/UIKit
bindable `ChatSession`. Dependency-free; iOS 15+ / macOS 12+.
