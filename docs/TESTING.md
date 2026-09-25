# Testing Myna Flow as if on another Mac

Most of what goes wrong with Myna Flow on someone else's Mac is about
**permissions**, and permissions are the one thing you cannot test by running the
app you built on the Mac you built it on. This page is how to test them anyway.

## What "a fresh Mac" means for this app

Three grants matter, and they are not what they look like:

| Grant | What it covers | Where macOS keeps it |
|---|---|---|
| Microphone | Hearing you | Per user |
| Accessibility | Placing text at the cursor, reading a selection | **System-wide**, per app *signature* |
| Input Monitoring | Noticing that you pressed the shortcut | **System-wide**, per app *signature* |

"Per signature" is the part that bites. macOS remembers a grant against the app's
code-signing **designated requirement**, not its name or path. Two copies of Myna Flow
signed differently are two different apps to macOS, however identical they look —
System Settings shows one "Myna Flow" row switched on, and only one of the copies is
actually allowed. Build from source on one Mac, download the zip on another, and you
have two signatures. Reinstall after the signing identity changes, same thing.

There is a second trap: the app learns its Accessibility state **once per process**.
Grant it while the app is running and the app may keep reading "off" until it is
reopened. Setup offers *Quit and reopen Myna Flow* for exactly this.

Everything in **Audio & General ▸ Permissions** exists to make these visible: the live
state of each grant as *this running copy* sees it, what this copy is signed as, and
every other copy of the app installed under the same name, flagged if it is signed
differently. **Copy report** puts all of it on the clipboard for a bug report.

### Asking the app from a script

The app answers `--print-permissions` with the same report as JSON, before any UI:

```bash
open -n -W --stdout /tmp/p.json -a "/Applications/Myna Flow.app" --args --print-permissions
plutil -extract accessibility raw -o - /tmp/p.json
```

Launch it **through `open`**, never by running the binary from a shell. A process
started from a terminal is *responsible to* the terminal, and macOS answers for the
terminal's grants — the wrong question. We verified this: the same binary reports
`accessibility=false` via `open` and `true` when exec'd from Terminal. `-n` allows a
second instance next to the running app, `-W` waits, and `--stdout` is how a menu-bar
app's output escapes `open`, which does not pass through the exit code either.

## On this Mac: `Scripts/test-fresh-install.sh`

Resets this Mac to "never seen Myna Flow" — data, caches, preferences and all three
privacy grants — installs the way a real person would, launches, and polls the app's
own report until you have granted everything. Prints a before/after table, the
identity, any other copies, and the findings. Needs the GUI session; the prompts are
yours to click.

```bash
./Scripts/test-fresh-install.sh --release dist/MynaFlow-1.1.4.zip   # what family gets: quarantined, right-click ▸ Open
./Scripts/test-fresh-install.sh --source                            # build here; Apple Development if you have it
./Scripts/test-fresh-install.sh --source --self-signed              # a Mac with no developer certificate
./Scripts/test-fresh-install.sh --adhoc-first                       # then run --source --self-signed …
```

That last pair reproduces the classic complaint: an early `install.sh` signed ad-hoc,
the permission was granted to that hash, and every rebuild since is a different app.
After `--adhoc-first` and a grant, `--source --self-signed` should show install.sh's
identity-change warning and Accessibility reading *off* until you re-add it.
`--keep-models` sets the downloaded models aside and puts them back, so a run costs
minutes rather than gigabytes.

## A real second Mac, on this Mac: Tart

For the cases a reset cannot reach — Gatekeeper on a genuine download, a machine with
no developer certificate, an untouched Launch Services database — run macOS in a VM.
Apple Silicon only. The VM window opens on this Mac, so every permission prompt and
right-click ▸ Open happens here.

```bash
# The Homebrew tap is broken under Homebrew 7; use Cirrus Labs' signed release directly.
curl -sSL https://github.com/cirruslabs/tart/releases/latest/download/tart.tar.gz | tar -xz -C ~/.local/bin
ln -sf ~/.local/bin/tart.app/Contents/MacOS/tart ~/.local/bin/tart

# One golden image with Xcode (tens of GB down, ~90 GB on disk). Clones are
# copy-on-write, so a working clone costs nothing until it diverges.
tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest mynaflow-golden
tart clone mynaflow-golden mynaflow-test

# Share this clone in; copy it inside before building (VirtioFS is slow for .build).
tart run mynaflow-test --dir=repo:$HOME/Documents/MynaFlow
```

From a script, use a shell *function* for ssh, not a string — zsh does not
word-split `$SSH`, and "no such file or directory: sshpass -p admin ssh …" cost
an hour looking like a network problem:

```bash
guest() { sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@"$IP" "$@"; }
```

There is no guest agent in this image (`tart exec` prints nothing); ssh is the
way in. If SwiftPM complains that `build.db` is malformed after a clone, `rm -rf
.build` — it is a copy-on-write artefact, not a project problem.

Inside the VM (user `admin`, password `admin`):

```bash
rsync -a --exclude .build --exclude dist "/Volumes/My Shared Files/repo/" ~/MynaFlow/
cd ~/MynaFlow && ./Scripts/install.sh          # takes the self-signed path: no developer cert here
./Scripts/test-fresh-install.sh --source --self-signed
```

Back to a clean machine in seconds: `tart delete mynaflow-test && tart clone mynaflow-golden mynaflow-test`.
Use `macos-tahoe-vanilla` (about a third the size) if you only need the download scenario.

What a VM cannot do: reproduce an **employer's management profile**. If a work Mac's
Accessibility list says *"configured by a profile"* and the grant keeps switching
itself off, that is the profile, and the report will show Accessibility flipping to
off with no reinstall in between. Take that report to whoever manages the Mac.
Also: no App Store or iCloud sign-in inside a VM, and two macOS VMs per host at most.

## What the VM found on its first day

On a fresh macOS 26 machine with no developer certificate, `install.sh` could not
create its self-signed certificate — `security import` into the login keychain
fails with *"User interaction is not allowed"* whenever that keychain is locked or
cannot show a dialog — and then **silently installed ad-hoc**, which is precisely
the state where the permission grant dies on every rebuild. It had worked on the
development Mac only because that keychain was unlocked with a window server behind
it. Since 1.1.4 the certificate lives in its own keychain
(`~/Library/Keychains/mynaflow-signing.keychain-db`, empty password, no auto-lock,
codesign pre-authorised) so it never needs a dialog, the reason for any failure is
printed, and `install.sh` refuses to fall back to ad-hoc unless you set
`ALLOW_ADHOC=1` yourself. Verified in the VM: a first install mints the certificate,
a second install keeps the identical designated requirement.

### Seen live, on this Mac

`test-fresh-install.sh --adhoc-first`, grant everything, then
`--source --self-signed --no-reset`: System Settings kept showing one "Myna Flow"
row switched on under both Accessibility and Input Monitoring, and the rebuilt app
read Accessibility off and Input Monitoring denied. Quitting and reopening changed
nothing. Removing the row and adding the app back *while it was running* changed
nothing either — macOS re-created the old row from the running copy's identity
before the new one could take. What recovered it: quit the app, remove the row
(`tccutil reset ListenEvent com.itssrb24.MynaFlow` does the same as **–**), relaunch;
the app was granted on the spot, from the approval given minutes earlier — and the
pane showed **no row at all** while the app read granted. The pane is not the
truth; `--print-permissions` is. That is the entire "granted but not granted" complaint,
reproducible on demand.

## Why not just a second user account

It is tempting — `SrbGuest` is right there — but it only half works. Microphone and the
app's data are per user, so a second account gives clean onboarding and a fresh
microphone prompt. **Accessibility and Input Monitoring are system-wide** and shared
by every account on the Mac, so they arrive already granted. Use `tccutil reset` (the
harness does) for those, or a VM.

## Reading a report

| Finding | Meaning | Do |
|---|---|---|
| *Another copy … is signed differently* | Two apps to macOS; the grant may belong to the other one | Delete the copy you are not using, re-grant, reopen |
| *This copy is ad-hoc signed* | The grant dies on the next rebuild | Rebuild with the current `install.sh`, re-grant |
| *Running from a translocated path* | Opened from Downloads while quarantined | Move to /Applications, reopen |
| *Accessibility reads as off … quit and reopen* | Per-process cache, or a profile | Relaunch; if it persists, check Device Management |
