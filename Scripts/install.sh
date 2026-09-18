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
CERT_NAME="Myna Flow"

existing_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"'
}

have_local_cert() {
  # No -v here: that filters to identities with a trusted chain, and a
  # self-signed certificate never has one. It still signs perfectly well,
  # and macOS only cares that the identity is stable between builds.
  security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""
}

create_local_cert() {
  local dir
  dir=$(mktemp -d)
  cat > "$dir/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Myna Flow
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
# Apple's "code signing" certificate marker.
1.2.840.113635.100.6.1.13 = DER:0500
CNF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/openssl.cnf" >/dev/null 2>&1 || return 1
  openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/id.p12" -name "$CERT_NAME" -passout pass:mynaflow >/dev/null 2>&1 || return 1
  security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P mynaflow -T /usr/bin/codesign -A >/dev/null 2>&1 || { rm -rf "$dir"; return 1; }
  rm -rf "$dir"
  have_local_cert
}

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
