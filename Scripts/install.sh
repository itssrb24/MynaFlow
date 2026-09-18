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

print_step "Building (a few minutes the first time)"
ALLOW_ADHOC=1 ./Scripts/build-app.sh >/dev/null

APP="dist/Myna Flow.app"
if [[ -d "/Applications/Myna Flow.app" ]]; then
  print_step "Replacing the existing copy"
  osascript -e 'tell application "Myna Flow" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/Myna Flow.app"
fi

print_step "Installing to /Applications"
cp -R "$APP" /Applications/
open "/Applications/Myna Flow.app"

cat <<'DONE'

Installed. Myna Flow is in your menu bar — it has no Dock icon.

It will ask for two permissions, and needs both:
  • Microphone      so it can hear you
  • Accessibility   so it can type into other apps

If the shortcut does nothing right after you grant Accessibility, quit Myna
Flow from the menu bar and open it again.

Then: hold Command-Shift-Space, say a sentence, let go.
DONE
