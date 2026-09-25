#!/bin/zsh
# Builds Myna Flow from source and installs it into /Applications.
#
# This is the path with no Gatekeeper warning. The warning people see on a
# downloaded build comes from the quarantine flag macOS stamps on downloaded
# files — an app built here never gets one, so it just opens.
set -euo pipefail

cd "$(dirname "$0")/.."

print_step() { print -P "%F{blue}==>%f $1" }
print_bad()  { print -P "%F{red}error:%f $1" >&2 }

# 1. macOS version. The app uses SpeechAnalyzer, which is macOS 26 and later.
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MAJOR < 26 )); then
  print_bad "Myna Flow needs macOS 26 or later. This Mac is on $(sw_vers -productVersion)."
  print "Nothing has been installed."
  exit 1
fi

# 2. Toolchain.
if ! command -v swift >/dev/null 2>&1; then
  print_bad "Swift isn't installed."
  print "Install Xcode from the App Store, open it once to finish setup, then run this again."
  exit 1
fi

# 3. A stable signing identity.
#
# This matters more than it looks. macOS ties an Accessibility grant to the
# identity of the binary. An ad-hoc signature has no identity, so the grant is
# pinned to the exact bytes: rebuild the app and the grant silently stops
# applying, while the checkbox in System Settings stays on. The app then reads
# as untrusted, cannot see any focused text field, and every dictation falls
# back to the scratchpad instead of landing at the cursor.
#
# So: use a real identity if the machine has one, otherwise mint a local
# self-signed one once and reuse it forever.
source "$(dirname "$0")/lib/signing.sh"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  : # caller knows what they want
elif [[ -n "$(existing_identity)" ]]; then
  export SIGN_IDENTITY="$(existing_identity)"
elif have_local_cert; then
  export SIGN_IDENTITY="$CERT_NAME"
elif print_step "Creating a local signing certificate (once)" && create_local_cert; then
  export SIGN_IDENTITY="$CERT_NAME"
else
  print_bad "Could not create a signing certificate."
  print "Myna Flow will be installed with an ad-hoc signature. It will work,"
  print "but macOS forgets its Accessibility permission every time you rebuild,"
  print "and dictation then falls back to the scratchpad instead of typing."
  print "If that happens: System Settings > Privacy & Security > Accessibility,"
  print "select Myna Flow, press the minus button, add it again, then restart it."
  export ALLOW_ADHOC=1
fi

print_step "Building (a few minutes the first time)"
./Scripts/build-app.sh >/dev/null

APP="dist/Myna Flow.app"
if [[ -d "/Applications/Myna Flow.app" ]]; then
  # macOS keys Accessibility and Input Monitoring to the signature. If this
  # build is signed differently from the installed copy, the old grant stops
  # applying while System Settings still shows it on — the single most
  # confusing failure this app has. Say so before it happens.
  OLD_DR=$(designated_requirement "/Applications/Myna Flow.app")
  NEW_DR=$(designated_requirement "$APP")
  if [[ -n "$OLD_DR" && "$OLD_DR" != "$NEW_DR" ]]; then
    print -P "%F{yellow}warning:%f the installed copy is signed as $(signing_authority '/Applications/Myna Flow.app');"
    print "  this build is signed as $(signing_authority "$APP")."
    print "  macOS treats it as a new app: re-grant Accessibility and Input Monitoring after it opens"
    print "  (System Settings > Privacy & Security; remove the old row with -, add the app again with +)."
  fi
  print_step "Replacing the existing copy"
  osascript -e 'tell application "Myna Flow" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/Myna Flow.app"
fi

print_step "Installing to /Applications"
cp -R "$APP" /Applications/
# Never leave a second copy inside the clone. Launch Services registers it,
# System Settings can be granting it, and the copy in /Applications is then
# the one that reads as not allowed.
rm -rf "$APP"

print_step "Identity: $(signing_authority '/Applications/Myna Flow.app')"
for other in $(other_copies "/Applications/Myna Flow.app"); do
  if [[ "$(designated_requirement "$other")" != "$(designated_requirement '/Applications/Myna Flow.app')" ]]; then
    print -P "%F{yellow}warning:%f another copy at $other is signed differently."
    print "  Remove it, or System Settings may be granting that one instead of this one."
  fi
done
open "/Applications/Myna Flow.app"

cat <<'DONE'

Installed. Myna Flow is in your menu bar — it has no Dock icon.

It will ask for two permissions, and needs both:
  • Microphone      so it can hear you
  • Accessibility   so it can type into other apps

Audio & General > Permissions shows what macOS actually granted this copy.

If the shortcut does nothing right after you grant Accessibility, quit Myna
Flow from the menu bar and open it again.

Then: hold Command-Shift-Space, say a sentence, let go.
DONE
