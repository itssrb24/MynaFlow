#!/bin/zsh
# Builds dist/Myna Flow.app from the SwiftPM release binary.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

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
  /usr/bin/codesign --force --sign - "$binary"
done

/usr/bin/codesign --force --deep --sign - "$APP"
echo "Built $APP"
