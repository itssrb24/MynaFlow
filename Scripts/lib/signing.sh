#!/bin/zsh
# Shared by install.sh and test-fresh-install.sh. Source it; do not run it.

CERT_NAME="Myna Flow"
BUNDLE_ID="com.itssrb24.MynaFlow"

existing_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"'
}

# The certificate lives in its own keychain, not the login keychain. Importing
# into the login keychain needs it unlocked and willing to show a dialog, and
# on a fresh Mac — or over ssh, or under a management profile — it is neither:
# `security import` fails with "User interaction is not allowed", and before
# this change install.sh then quietly signed ad-hoc, which is the one outcome
# this whole mechanism exists to prevent. A dedicated keychain with an empty
# password, no auto-lock, and codesign pre-authorised never prompts anyone.
MYNA_KEYCHAIN="$HOME/Library/Keychains/mynaflow-signing.keychain-db"

have_local_cert() {
  # No -v: that filters to identities with a trusted chain, and a self-signed
  # certificate never has one. It still signs perfectly well.
  security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""
}

# Prints the reason on stderr when it fails; a silent failure here cost days.
create_local_cert() {
  local dir log
  dir=$(mktemp -d); log="$dir/steps.log"
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
  {
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/openssl.cnf" &&
    openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
      -out "$dir/id.p12" -name "$CERT_NAME" -passout pass:mynaflow &&
    { [[ -f "$MYNA_KEYCHAIN" ]] || security create-keychain -p "" "$MYNA_KEYCHAIN"; } &&
    security set-keychain-settings "$MYNA_KEYCHAIN" &&           # no auto-lock, ever
    security unlock-keychain -p "" "$MYNA_KEYCHAIN" &&
    security import "$dir/id.p12" -k "$MYNA_KEYCHAIN" -P mynaflow -T /usr/bin/codesign -A &&
    # Let codesign use the key without a prompt, and put the keychain where
    # codesign and find-identity will look.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$MYNA_KEYCHAIN" &&
    security list-keychains -d user -s "$MYNA_KEYCHAIN" $(security list-keychains -d user | tr -d '"' | grep -v mynaflow-signing)
  } >"$log" 2>&1 || {
    print "create_local_cert failed:" >&2
    grep -v "^\.\|^+\|^-----\|^Generating\|^writing" "$log" | tail -6 | sed 's/^/  /' >&2
    rm -rf "$dir"; return 1
  }
  rm -rf "$dir"
  have_local_cert
}

# The designated requirement is what macOS keys a permission grant to.
designated_requirement() {
  # codesign prefixes an ad-hoc requirement with "# " — the one case where the
  # warning matters most is the one a naive match silently skipped.
  codesign -d -r- "$1" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p'
}

signing_authority() {
  # An ad-hoc signature has no certificate and so no Authority= line; say so
  # rather than printing an empty name into a sentence.
  local out
  out=$(codesign -dvv "$1" 2>&1)
  if print -r -- "$out" | grep -q '^Signature=adhoc'; then
    print "ad-hoc (no certificate)"
  else
    print -r -- "$out" | sed -n 's/^Authority=//p' | head -1
  fi
}

# Ask an installed copy for its own permission report. Must go through Launch
# Services: exec'd from a shell the process is responsible *to the shell*, and
# TCC answers for the shell's grants instead of the app's.
print_permissions() {   # $1 = app bundle, $2 = output json path
  rm -f "$2"
  open -n -W --stdout "$2" --stderr /dev/null -a "$1" --args --print-permissions
  [[ -s "$2" ]]
}

# Every other bundle with our id that Spotlight knows about. Empty output means
# "none found", which, if Spotlight is off, is not the same as "none".
other_copies() {   # $1 = the path to exclude
  mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | grep -vxF "$1" || true
}
