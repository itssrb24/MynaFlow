# Myna Flow

Local-first dictation for macOS. Hold a key, talk, release. The words land
where your cursor is.

Nothing you say leaves the Mac. Transcription runs on the machine, the history
is a plain SQLite file in your own Library folder, and the app asks for two
permissions and no others.

## Requirements

**macOS 26 or later**, on Apple silicon. This is not negotiable: dictation uses
`SpeechAnalyzer`, the system transcriber introduced in macOS 26. On anything
older the app installs and then refuses to launch.

## Installing

Two ways, both in [INSTALL.md](INSTALL.md):

- **Download the zip** and right-click ▸ Open the first time. The warning is
  because the app is not notarized, which needs a paid Apple Developer
  account; it is signed either way.
- **Build it yourself** with `./Scripts/install.sh`, which has no warning at
  all — the prompt comes from the quarantine flag macOS puts on downloads, and
  an app built on your own Mac never gets one.

## What it does

- **Hold to talk** (⌘⇧Space by default) or **toggle** (⌘⌃Space). Release, and
  the text is typed into whatever app is focused.
- **Cleanup** removes filler words and stutters without changing meaning. Your
  own filler words can be added; Vocabulary terms are never treated as filler.
- **Polish** rewrites a selection in a style, using a local language model you
  download explicitly. Nothing is polished unless you ask.
- **Per-app rules** — skip cleanup, drop the trailing period, or auto-polish,
  per application.
- **History, Insights, Vocabulary, Learning** — all local, all inspectable,
  all deletable.

Two speech engines: Apple's, built into macOS, and Parakeet via FluidAudio,
which is more accurate on names and jargon and is an explicit ~600 MB download.

## Privacy, stated plainly

- **Audio** is written to a scratch file while you speak and deleted the moment
  it has been transcribed, on every path including failures and cancellation.
  Leftovers from a crash are swept at the next launch.
- **The network** is used for exactly three things, all of which you start:
  downloading a polish model from huggingface.co (pinned to a commit and
  verified against a SHA-256 before use), downloading the Parakeet model
  through FluidAudio (pinned to huggingface.co), and Apple's own download of
  its speech assets the first time you dictate. The polish model runs on
  127.0.0.1. There is no telemetry, no analytics, no crash reporting and no
  update check.
- **Accessibility is a real power.** The app holds it so it can put text at
  your cursor, and that same permission lets it read the focused text field of
  any application. It is used narrowly: read the selection when you ask for a
  polish, write at the cursor when you dictate. The protection is not a
  sandbox — Accessibility and the sandbox are mutually exclusive — it is that
  the code is here and the use is narrow.
- **Password fields**: dictated text is never inserted into a secure field and
  never placed on the clipboard when one is focused. When the app cannot tell
  where keyboard focus is and the window contains a password field, it refuses
  rather than guessing.
- **The clipboard** is used as the insertion mechanism and as the fallback when
  insertion fails. Those writes are marked concealed and transient so clipboard
  managers skip them, and the previous contents are restored afterwards.
- **The diagnostics log** records outcomes and errors, never what you said, and
  passes through a redactor before being written.

Everything lives in `~/Library/Application Support/Myna Flow/` — the database
is `0600`, the directories `0700`, re-asserted on every launch.

## Building

```bash
swift build          # or: swift test
./Scripts/build-app.sh   # signs and assembles dist/Myna Flow.app
./Scripts/release.sh     # also produces the distributable zip
```

Signing uses the first "Apple Development" identity in your keychain, or set
`SIGN_IDENTITY` explicitly. The build fails rather than silently falling back
to an ad-hoc signature, because an ad-hoc bundle gets a weak, path-based
Accessibility grant.

## Third-party code

- **ThinkingOrbsKit** — the animated orbs, MIT, © 2026 Jakub Antalik. Vendored
  verbatim in `Sources/ThinkingOrbsKit`; see its `UPSTREAM.md`.
- **FluidAudio** — Parakeet speech recognition, fetched by SwiftPM.
- **llama.cpp** — the polish model server, prebuilt binaries in
  `Sources/MynaFlowApp/Resources/Runtimes`, verified against a checksum
  manifest before the app will spawn them.

## Licence

MIT, see [LICENSE](LICENSE).
