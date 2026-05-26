# CLAUDE.md

This repo is the **PolyMessaging iOS SDK**. Most agent guidance lives in the
tool-agnostic brief below — read it before helping a developer integrate the SDK.

@AGENTS.md

## For Claude Code specifically

- **Helping a developer integrate the SDK into their app?** Follow `AGENTS.md` (imported
  above): drive everything through `ChatSession`, copy components from
  `Examples/SwiftUI/06-FullReference/Components/` or
  `Examples/UIKit/06-FullReference/Components/`, and keep snippets consistent with `README.md`.
- **Working ON the SDK itself** (editing `Sources/PolyMessaging/**`, the wire protocol,
  reconnection, the example ladder)? Follow the existing architecture and the correctness
  invariants the code comments call out, and mirror any change across the SwiftUI and
  UIKit example ladders.
- Keep `README.md` and the example apps in sync when you change either.
