#!/bin/zsh
# Puts THIS Mac into the state of a Mac that has never seen Myna Flow, installs
# it the way a real person would, and reports what macOS granted — as the app
# itself sees it. Needs a GUI session: the permission prompts are yours to click.
#
#   test-fresh-install.sh --release <zip>          a downloaded build, Gatekeeper and all
#   test-fresh-install.sh --source                 build from this clone (Apple Development if present)
#   test-fresh-install.sh --source --self-signed   build as a Mac with no developer certificate
#   test-fresh-install.sh --adhoc-first            install ad-hoc, then rerun --source --self-signed:
#                                                  reproduces "granted in Settings, off in the app"
#   options: --keep-models   --timeout <seconds>
#            --no-reset       keep the current grants across the reinstall: this is how you
#                             watch a grant made for one signature fail to apply to the next
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/signing.sh

print_step() { print -P "%F{blue}==>%f $1" }
print_bad()  { print -P "%F{red}error:%f $1" >&2 }

MODE=""; ZIP=""; SELF_SIGNED=0; KEEP_MODELS=0; TIMEOUT=600; NO_RESET=0
while (( $# )); do
  case "$1" in
    --release) MODE=release; ZIP="$2"; shift 2 ;;
    --source) MODE=source; shift ;;
    --adhoc-first) MODE=adhoc; shift ;;
    --self-signed) SELF_SIGNED=1; shift ;;
    --keep-models) KEEP_MODELS=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --no-reset) NO_RESET=1; shift ;;
    *) print_bad "unknown option $1"; exit 2 ;;
  esac
done
[[ -n "$MODE" ]] || { print_bad "pick --release <zip>, --source or --adhoc-first"; exit 2; }
[[ "$(id -u)" != 0 ]] || { print_bad "do not run under sudo: prompts go to the GUI session"; exit 2; }

INSTALLED="/Applications/Myna Flow.app"
SUPPORT="$HOME/Library/Application Support/Myna Flow"
SCRATCH=$(mktemp -d)

print_step "Quitting any running copy"
osascript -e 'tell application "Myna Flow" to quit' >/dev/null 2>&1 || true
pkill -x MynaFlow 2>/dev/null || true
for _ in {1..10}; do pgrep -x MynaFlow >/dev/null || break; sleep 0.5; done

if (( KEEP_MODELS )) && [[ -d "$SUPPORT/Models" ]]; then
  print_step "Setting models aside"
  mv "$SUPPORT/Models" "$SCRATCH/Models.keep"
fi

print_step "Wiping everything the app ever wrote"
rm -rf "$SUPPORT" \
  "$HOME/Library/Caches/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
killall cfprefsd 2>/dev/null || true    # or it rewrites the plist from memory
# The login-item registration lives in a system database and has no bearing on
# permissions, so it is deliberately left alone.

case "$MODE" in
  release)
    print_step "Installing from $ZIP as a download"
    ditto -x -k "$ZIP" "$SCRATCH/unzip"
    STAGED=$(find "$SCRATCH/unzip" -maxdepth 3 -name "*.app" | head -1)
    [[ -n "$STAGED" ]] || { print_bad "no .app inside the zip"; exit 1; }
    # The zip is built without extended attributes, so a browser would be the
    # one to add the quarantine flag. Add it by hand: this is what makes macOS
    # show the "cannot verify the developer" dialog on first open.
    xattr -r -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$STAGED"
    # A person drags the app from Downloads into Applications with Finder.
    # That drag is what tells macOS the app has been "moved by the user"; a
    # plain cp keeps the quarantine flag but not that fact, and the app then
    # launches translocated from a read-only mirror under /private/var.
    # Known limit: with a hand-written quarantine record even this Finder move
    # still translocates, so a --release run will report translocation. Only a
    # real Safari download dragged by hand is free of it (docs/TESTING.md).
    rm -rf "$INSTALLED" "$HOME/Downloads/Myna Flow.app"
    mv "$STAGED" "$HOME/Downloads/"
    osascript -e 'tell application "Finder" to move (POSIX file "'"$HOME/Downloads/Myna Flow.app"'" as alias) to (POSIX file "/Applications" as alias)' >/dev/null
    [[ -d "$INSTALLED" ]] || { print_bad "Finder did not move the app into /Applications"; exit 1; }
    ;;
  source)
    print_step "Installing from source$([[ $SELF_SIGNED == 1 ]] && print ' (self-signed, as a Mac with no developer certificate)')"
    if (( SELF_SIGNED )); then
      have_local_cert || create_local_cert || { print_bad "could not create the local certificate"; exit 1; }
      SIGN_IDENTITY="$CERT_NAME" ./Scripts/install.sh
    else
      ./Scripts/install.sh
    fi
    osascript -e 'tell application "Myna Flow" to quit' >/dev/null 2>&1 || true; sleep 1
    ;;
  adhoc)
    print_step "Installing AD-HOC, the way install.sh did before 1.1.0"
    ALLOW_ADHOC=1 SIGN_IDENTITY="-" ./Scripts/build-app.sh >/dev/null
    rm -rf "$INSTALLED"; cp -R "dist/Myna Flow.app" /Applications/; rm -rf "dist/Myna Flow.app"
    ;;
esac

if (( KEEP_MODELS )) && [[ -d "$SCRATCH/Models.keep" ]]; then
  mkdir -p "$SUPPORT"; mv "$SCRATCH/Models.keep" "$SUPPORT/Models"
fi

if (( NO_RESET )); then
  print_step "Keeping existing privacy grants (--no-reset)"
else
  print_step "Resetting privacy grants (after install: tccutil needs the bundle resolvable)"
  for svc in Microphone Accessibility ListenEvent; do
    tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1 || print "  ($svc: nothing to reset)"
  done
fi

grant() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || print "?" }
print_step "Baseline, before launch"
if print_permissions "$INSTALLED" "$SCRATCH/before.json"; then
  printf '  %-18s mic=%s  accessibility=%s  input-monitoring=%s\n' before \
    "$(grant microphone "$SCRATCH/before.json")" "$(grant accessibility "$SCRATCH/before.json")" "$(grant inputMonitoring "$SCRATCH/before.json")"
elif [[ "$MODE" == release ]]; then
  # Gatekeeper will not let `open` launch a quarantined, un-notarized app at
  # all until a person has done right-click > Open once. That is the point
  # of this mode, so the baseline is simply unavailable until then.
  print "  (quarantined: no baseline until you have opened it once yourself)"
  print '{"microphone":"notDetermined","accessibility":false,"inputMonitoring":"notDetermined"}' > "$SCRATCH/before.json"
else
  print_bad "--print-permissions produced nothing"; exit 1
fi

print_step "Launching"
if [[ "$MODE" == release ]]; then
  print "  This copy is quarantined. Open it yourself: Finder > Applications > right-click Myna Flow > Open."
else
  open "$INSTALLED"
fi
print "  Grant Microphone, Accessibility and Input Monitoring when asked. Polling for up to ${TIMEOUT}s."

deadline=$(( $(date +%s) + TIMEOUT ))
while (( $(date +%s) < deadline )); do
  sleep 3
  print_permissions "$INSTALLED" "$SCRATCH/now.json" || continue
  m=$(grant microphone "$SCRATCH/now.json"); a=$(grant accessibility "$SCRATCH/now.json"); i=$(grant inputMonitoring "$SCRATCH/now.json")
  printf '\r  now                mic=%-13s accessibility=%-6s input-monitoring=%-13s' "$m" "$a" "$i"
  [[ "$m" == granted && "$a" == true && "$i" == granted ]] && break
done
print

print_step "Result"
cp "$SCRATCH/now.json" "$SCRATCH/after.json" 2>/dev/null || cp "$SCRATCH/before.json" "$SCRATCH/after.json"
printf '  %-18s %-14s %-14s\n' permission before after
for k in microphone accessibility inputMonitoring; do
  printf '  %-18s %-14s %-14s\n' "$k" "$(grant $k "$SCRATCH/before.json")" "$(grant $k "$SCRATCH/after.json")"
done
auth=$(grant app.authority.0 "$SCRATCH/after.json"); [[ "$auth" == "?" ]] && auth="(no certificate)"
print "  identity:     $auth [$(grant app.signature "$SCRATCH/after.json"), $(grant app.fingerprint "$SCRATCH/after.json" | cut -c1-8)]"
print "  other copies: $(grant otherCopies "$SCRATCH/after.json")"
n=$(grant findings "$SCRATCH/after.json"); print "  findings:     $n"
for (( j=0; j<${n:-0}; j++ )); do print "    - $(grant "findings.$j.text" "$SCRATCH/after.json")"; done
print "  log:"
grep -aE "startup:|identity=|permission|accessibility|input monitoring" "$SUPPORT/Diagnostics/flow.log" 2>/dev/null | tail -n 8 | sed 's/^/    /'

ok=1
[[ "$(grant microphone "$SCRATCH/after.json")" == granted ]] || ok=0
[[ "$(grant accessibility "$SCRATCH/after.json")" == true ]] || ok=0
[[ "$(grant inputMonitoring "$SCRATCH/after.json")" == granted ]] || ok=0
warnings=$(plutil -extract findings json -o - "$SCRATCH/after.json" 2>/dev/null | grep -c '"warning"' || true)
(( warnings == 0 )) || ok=0
(( ok )) && print -P "%F{green}PASS%f" || { print -P "%F{red}FAIL%f"; exit 1; }
