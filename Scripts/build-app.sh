#!/bin/zsh
# Builds dist/Myna Flow.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

# A stable identity keeps TCC grants (Accessibility, mic) across rebuilds;
# ad-hoc signatures change every build and macOS holds a stale entry.
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
SIGN_IDENTITY=${SIGN_IDENTITY:--}
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
for binary in "$RUNTIMES_DST"/*; do
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$binary"
done
# Seal the manifest the app verifies at launch AFTER signing: signing rewrites
# the Mach-O files, so the upstream (unsigned) sums in the source tree would
# never match. The source SHA256SUMS remains the provenance record.
(cd "$RUNTIMES_DST" && /usr/bin/shasum -a 256 llama-server llama-cli *.dylib > SHA256SUMS)

/usr/bin/codesign --force --deep --options runtime --entitlements Packaging/MynaFlow.entitlements --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"
