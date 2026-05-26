## Summary

<!-- One or two sentences: what does this change do, at a user-visible level? -->

## Motivation

<!-- Why is this change needed? Link the issue if one exists. -->

Closes #

## Changes

<!-- Bullet the meaningful changes — not a diff summary, but a reviewer's roadmap. -->

-
-

## Test strategy

- [ ] `swift build` succeeds
- [ ] `swift test` passes
- [ ] If public API changed: relevant example app updated and `scripts/build-all.sh` passes
- [ ] Manual run in simulator (which example, which OS version)
- [ ] If the wire protocol or reconnection logic changed: tested against a live Agent Studio environment

## Checklist

- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] No third-party dependencies added to `Package.swift`
- [ ] No API keys, session IDs, or credentials in the diff
- [ ] `README.md` updated if public API or behavior changed
- [ ] SwiftUI and UIKit example ladders mirrored (if SDK behavior changed)
- [ ] `Version.swift` not edited by hand (release-please owns it)

## Screenshots / recordings

<!-- For UI-affecting changes, drop a screenshot or short clip from the simulator. -->

## Logs

<!-- For reconnection / wire-protocol / streaming changes, paste relevant log excerpts (redact tokens). -->
