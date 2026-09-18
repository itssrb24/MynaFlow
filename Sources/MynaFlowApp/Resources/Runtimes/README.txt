llama.cpp runtimes
==================

These are prebuilt llama.cpp binaries, used only for the optional "polish"
feature, which rewrites a selection using a language model you download
yourself. Dictation does not use them at all: you can delete this directory
and transcription still works.

What runs, and how
------------------
llama-server is the fast path. It is started bound to 127.0.0.1 on an
ephemeral port so the model loads once and stays resident between requests,
and it is torn down when the app quits or after an idle timeout. It never
binds a public interface. Requests carry a per-spawn bearer token passed
through the environment rather than argv, so it does not appear in `ps`.
If the server cannot start, the app falls back to spawning llama-cli per
request. Inference is local either way.

Before spawning either one, the app verifies every file here against
SHA256SUMS (see Sources/MynaFlowCore/Platform/RuntimeIntegrity.swift) and
refuses to run if anything has changed. That manifest is regenerated during
the signed build, after the binaries are signed and before the app bundle is
sealed, so it ends up inside the app's own code signature — swapping a dylib
means forging the manifest and breaking the signature too.

Provenance — read this if you are auditing the repo
---------------------------------------------------
Being honest about what is and is not verifiable here:

  Verifiable from this repo
    - arm64 Mach-O, built 2026-08-04
    - llama.cpp build 10042 and ggml 0.16.0, from the dylib install names
      (libllama.0.0.10042.dylib, libggml-base.0.16.0.dylib)
    - the SHA-256 of every file, in SHA256SUMS

  NOT verifiable from this repo
    - the exact upstream commit these were built from
    - the cmake flags and SDK used
    - who built them

The binaries are stripped, so there is no embedded version or build id to
recover. If you do not want to trust them, you have two good options:

  1. Delete this directory. Dictation is unaffected; only polish stops
     working, and the app tells you it is unavailable rather than failing
     oddly.
  2. Build llama.cpp yourself from a commit you choose, drop llama-server,
     llama-cli and their dylibs in here, and rebuild the app. The build
     script regenerates SHA256SUMS from whatever is present, so your own
     binaries will be the ones sealed and verified.

Replacing these with a documented, reproducible fetch of a pinned upstream
release is the right long-term fix and has not been done yet.
