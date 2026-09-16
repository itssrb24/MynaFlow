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
/usr/bin/codesign --force --deep --sign - "$APP"
echo "Built $APP"
