#!/bin/zsh
# Builds the distributable archive: dist/MynaFlow-<version>.zip
#
# Not notarized — that needs a paid Apple Developer account — so the archive
# ships with the instructions for the one-time right-click ▸ Open, and the
# version, checksum and requirements are printed for the release notes.
set -euo pipefail

cd "$(dirname "$0")/.."
./Scripts/build-app.sh

APP="dist/Myna Flow.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
MINIMUM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
STAGE="dist/stage"
ZIP="dist/MynaFlow-$VERSION.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp INSTALL.md "$STAGE/Read Me First.md"

# ditto rather than zip: it preserves the code signature and resource forks.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
rm -rf "$STAGE"

echo
echo "Built $ZIP"
echo "  version   $VERSION (requires macOS $MINIMUM)"
echo "  size      $(du -h "$ZIP" | cut -f1)"
echo "  sha256    $(/usr/bin/shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
/usr/bin/codesign --verify --strict "$APP" && echo "  signature verifies"
echo "  gatekeeper: $(/usr/sbin/spctl --assess --type execute "$APP" 2>&1 | tail -1)"
echo "  (rejected is expected without notarization — see INSTALL.md)"
