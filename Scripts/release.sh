#!/bin/zsh
# Builds the distributable archive: dist/MynaFlow-<version>.zip
#
# Not notarized — that needs a paid Apple Developer account — so the archive
# ships with the instructions for the one-time right-click ▸ Open, and the
# version, checksum and requirements are printed for the release notes.
set -euo pipefail

cd "$(dirname "$0")/.."

# Published builds are signed with a self-signed "Myna Flow" certificate
# rather than a personal Apple Development one, which would otherwise put the
# developer's email address in every copy of the download. Both are equally
# un-notarized, so this costs nothing at install time. Unlike an ad-hoc
# signature it keeps a stable identity, so Accessibility grants survive
# updates. Create one in Keychain Access ▸ Certificate Assistant ▸ Create a
# Certificate (Code Signing, self-signed) named "Myna Flow".
if security find-identity -p codesigning 2>/dev/null | grep -q '"Myna Flow"'; then
  export SIGN_IDENTITY="Myna Flow"
else
  echo "warning: no 'Myna Flow' signing certificate found." >&2
  echo "  Falling back to whatever build-app.sh picks, which may embed a" >&2
  echo "  personal email in the published signature." >&2
fi

# Neutral build path, so no home directory is baked into the shipped binary.
export SCRATCH="${TMPDIR:-/tmp}/mynaflow-release-build"
./Scripts/build-app.sh

APP="dist/Myna Flow.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
MINIMUM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
STAGE="dist/Myna Flow $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP="dist/MynaFlow-$VERSION.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
# --norsrc/--noextattr keep the archive free of __MACOSX and ._ entries.
cp -R "$APP" "$STAGE/"
cp INSTALL.md "$STAGE/Read Me First.md"

# ditto rather than zip: it preserves the code signature and resource forks.
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$ZIP"
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
