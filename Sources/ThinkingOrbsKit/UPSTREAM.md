# ThinkingOrbsKit — vendored, do not hand-edit

Source: `libraries.dev` monorepo,
`source/Libraries.dev/packages/thinking-orbs/ports/ios/ThinkingOrbsKit/Sources/ThinkingOrbsKit/`
(local checkout: `~/Documents/libraries-dev`).

- Version: **spec 1.0.0 · thinking-orbs 0.3.1** (from the `OrbSpec.swift` header)
- Licence: MIT © 2026 Jakub Antalik — see `LICENSE` beside this file
- Synced: 2026-09-18, byte-identical to upstream (`diff -r` clean)

## The rule

These ten files are a straight copy. **Never edit them.** Myna Flow's live
microphone reaction is applied on the way out instead: `ReactiveOrb` calls the
public `orbFrame(state:size:t:)` and deforms the returned dots before drawing
them, so the library stays re-syncable.

To re-sync: copy `Sources/ThinkingOrbsKit/*.swift` wholesale from upstream,
then run `swift test`. `Tests/ThinkingOrbsBridgeTests` is the canary — it
asserts the things the indicator depends on:

- the composing orb's faint ghost sphere and bright sash stay separable by
  alpha either side of 0.36 (`OrbLevelModulation.ghostAlphaThreshold`)
- dot counts per state hold, because the pill's measured CPU budget assumes them
- no dot leaves the orb's bounds once swelled to full level
- frames are deterministic, guarding the library's `nonisolated(unsafe)` cache

## Swift language mode

The target pins `.swiftLanguageMode(.v5)` because upstream is tools-version
5.9. Checked on sync: these files **also compile clean in Swift 6 mode** today.
The pin is insurance for the next sync, not a workaround for a current failure —
it keeps "copy ten files" from turning into a debugging session in code we have
promised not to touch. `MynaFlowApp` still gets full Swift 6 checking at the
boundary, since the public surface is `Sendable`.
