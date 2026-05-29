# Changelog

All notable changes to the PolyMessaging iOS SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org). While the SDK
is pre-1.0, breaking changes bump the **minor** version.

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
