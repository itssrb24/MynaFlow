#!/bin/zsh
# Builds dist/Myna Flow.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

# A stable identity keeps TCC grants (Accessibility, mic) across rebuilds;
# ad-hoc signatures change every build and macOS holds a stale entry. Worse,
# an ad-hoc bundle has no designated requirement, so its Accessibility grant
# degrades to a path-based one that any admin-writable replacement at the same
# path inherits. Never fall back to ad-hoc silently.
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: no signing identity found." >&2
  echo "  Set SIGN_IDENTITY to a certificate name, or ALLOW_ADHOC=1 to sign ad-hoc" >&2
  echo "  (ad-hoc is for local testing only — never distribute it)." >&2
  [[ "${ALLOW_ADHOC:-0}" == "1" ]] || exit 1
  SIGN_IDENTITY="-"
fi
echo "Signing with: $SIGN_IDENTITY"

APP="dist/Myna Flow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MynaFlow "$APP/Contents/MacOS/MynaFlow"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# llama.cpp runtimes (server + CLI + dylibs); provenance in SHA256SUMS.
RUNTIMES_SRC="Sources/MynaFlowApp/Resources/Runtimes"
RUNTIMES_DST="$APP/Contents/Resources/Runtimes"
mkdir -p "$RUNTIMES_DST"
rsync -a --exclude SHA256SUMS --exclude README.txt "$RUNTIMES_SRC/" "$RUNTIMES_DST/"

# --timestamp: without a secure timestamp every signature here stops being
# valid the day the signing certificate expires, and the app stops launching
# on machines that already have it. --options runtime: llama-server is spawned
# as its own process, so it does not inherit the app's hardened runtime; it
# has to be hardened in its own right.
SIGN_FLAGS=(--force --timestamp --options runtime)
[[ "$SIGN_IDENTITY" == "-" ]] && SIGN_FLAGS=(--force --options runtime)
for binary in "$RUNTIMES_DST"/*; do
  /usr/bin/codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$binary"
done
# Seal the manifest the app verifies at launch AFTER signing: signing rewrites
# the Mach-O files, so the upstream (unsigned) sums in the source tree would
# never match. The source SHA256SUMS remains the provenance record. Generating
# it here also puts it inside the bundle signature sealed below, so swapping a
# dylib means forging the manifest and breaking the app signature both.
(cd "$RUNTIMES_DST" && /usr/bin/shasum -a 256 llama-server llama-cli *.dylib > SHA256SUMS)

# Strip extended attributes before sealing: rsync carries them over, and
# pkgbuild re-encodes them as AppleDouble "._" files inside the signed bundle.
/usr/bin/xattr -cr "$APP"
# No --deep: Apple deprecated it for signing, and it silently skips the nested
# code that was already signed above, which is the opposite of what it implies.
/usr/bin/codesign "${SIGN_FLAGS[@]}" \
  --entitlements Packaging/MynaFlow.entitlements --sign "$SIGN_IDENTITY" "$APP"

/usr/bin/codesign --verify --strict --verbose=1 "$APP"
echo "Built $APP"
