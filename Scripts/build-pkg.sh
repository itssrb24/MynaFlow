#!/bin/zsh
# Builds dist/MynaFlow.pkg — installs Myna Flow.app into /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
./Scripts/build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "dist/Myna Flow.app/Contents/Info.plist")
pkgbuild \
  --component "dist/Myna Flow.app" \
  --install-location /Applications \
  --identifier com.itssrb24.MynaFlow.pkg \
  --version "$VERSION" \
  "dist/MynaFlow-$VERSION.pkg"
echo "Built dist/MynaFlow-$VERSION.pkg"
