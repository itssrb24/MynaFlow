# Installing Myna Flow

**You need macOS 26 or later.** Apple menu ▸ About This Mac tells you which
version you have. On anything older this app will not run at all — dictation
uses a system component that only exists from macOS 26.

There are two ways in. Pick one.

---

## Option A — download it (easiest)

1. Download the **MynaFlow zip** from the [releases page](https://github.com/itssrb24/MynaFlow/releases) and unzip it.
2. Drag **Myna Flow** into your **Applications** folder.
3. **Right-click** (or Control-click) the app and choose **Open**.
4. macOS says it cannot verify the developer. Click **Open**.

Step 3 matters: double-clicking the first time gives you a dialog with no way
forward, and right-click ▸ Open is the one that offers the Open button. You
only do this once.

### Why that warning appears

macOS stamps every downloaded file with a quarantine flag, and it will only
open a quarantined app without complaint if the developer paid Apple $99 a
year to have it notarized. This app is properly signed, just not notarized, so
you get one warning. It is about who paid Apple, not about what the app does.

**Do not run `xattr` or `sudo` commands you find online to silence warnings
like this.** Getting comfortable with that is exactly what malware relies on.
Right-click ▸ Open is the button Apple provides, and it is enough.

---

## Option B — build it yourself (no warning at all)

An app built on your own Mac was never downloaded, so it never gets the
quarantine flag, so there is no warning. You also get to read exactly what
you are running first.

You need **Xcode** from the App Store — it is a large download, so this path
suits you if you are comfortable in Terminal.

```bash
git clone https://github.com/itssrb24/MynaFlow.git
cd MynaFlow
./Scripts/install.sh
```

The script checks your macOS version, builds the app, installs it to
Applications, and opens it. To update later:

```bash
git pull && ./Scripts/install.sh
```

---

## First run, either way

Myna Flow lives in the menu bar and has no Dock icon. It will walk you
through:

1. **Microphone** — so it can hear you.
2. **Accessibility** — so it can type into other apps. macOS opens System
   Settings; switch Myna Flow on, then come back.
3. A first dictation, to prove it works.

If the shortcut does nothing right after you grant Accessibility, quit Myna
Flow from the menu bar and open it again.

## Using it

- **Hold ⌘⇧Space**, talk, let go. The text appears where your cursor is.
- **⌘⌃Space** starts and stops instead, for longer stretches.
- **Esc** cancels.
- Everything you dictate is kept in History, on your Mac, and can be deleted
  from there.

## Does it phone home?

No. After the first launch it opens no network connections at all. The only
times it uses the network are downloads you start yourself: the optional
Parakeet speech model, the optional polish model, and Apple's own one-time
download of its speech files the first time you dictate. There is no
telemetry, no analytics, no crash reporting and no update check.

If you want to see for yourself, this shows every network socket the app has
open — it should print nothing:

```bash
lsof -nP -i -a -p $(pgrep -x MynaFlow)
```

## The shortcut does nothing, but dictation works from the menu bar

Myna Flow needs **two** separate permissions to do its job, and they are easy to
confuse:

| Permission | What it covers |
|---|---|
| **Accessibility** | Placing the text at your cursor |
| **Input Monitoring** | *Noticing* that you pressed the shortcut |

With Accessibility but not Input Monitoring, everything works except the
shortcut: dictation started from the menu bar types perfectly, and pressing
⌘⇧Space does nothing at all. It looks like a broken hotkey; it is a missing
permission.

Since 1.1.2 the menu bar says so directly — *"Shortcuts are off — Input
Monitoring is not granted"* — with a button that opens the right pane. You can
also get there yourself:

System Settings ▸ Privacy & Security ▸ **Input Monitoring** ▸ **+** ▸ add Myna
Flow from Applications ▸ switch it on ▸ **quit and reopen Myna Flow**.

macOS does not always raise its own prompt for this one, and on a Mac managed by
an employer it may never appear, so adding it by hand is sometimes the only way.

## Every dictation opens the Scratchpad instead of typing

This means the app is not being trusted for Accessibility, even if the switch
in System Settings looks on. With no Accessibility, Myna Flow cannot see the
text field you are aimed at, so it puts the words somewhere you will not lose
them — the scratchpad — rather than typing into the unknown.

Since version 1.1.0 the pill says so directly: *"Accessibility is off —
re-enable it in System Settings"*. If you see that, work through this list.

**1. Look at Audio & General ▸ Permissions.** It shows what macOS actually granted
*this* copy, how the copy is signed, and every other copy of Myna Flow installed under
the same name — flagged if one is signed differently, which is the usual cause.
**Copy report** puts it all on the clipboard.

**2. Check how your copy is signed.** If your first install was before 1.1.4, it
may be ad-hoc even though you built from source: the certificate step used to fail
quietly on a Mac with a locked keychain and the script carried on. Re-run
`./Scripts/install.sh` — it now keeps its certificate in its own keychain, prints
the reason if anything fails, and stops rather than installing ad-hoc — then re-add
the permission once (step 3). It stays from then on.

```bash
codesign -dv "/Applications/Myna Flow.app" 2>&1 | grep -E "Signature|Authority"
```

If it prints `Signature=adhoc`, the build has no stable identity. macOS ties an
Accessibility grant to the identity of the binary, and an ad-hoc one is just
its hash — so the grant stops applying the moment you rebuild with any change,
while the checkbox stays on. Rebuild with the current `./Scripts/install.sh`,
which creates a proper local certificate the first time and reuses it forever,
then do step 2.

**3. Re-add the permission.** Turning it off and on again is not enough, and
neither is quitting and reopening the app — both were tried, on a copy whose
signature had just changed, and the app still read Input Monitoring as denied with
the switch showing on. The row itself belongs to the old signature:

1. System Settings ▸ Privacy & Security ▸ **Accessibility**
2. Select **Myna Flow**, press the **–** button to remove it
3. Press **+**, choose Myna Flow from Applications, make sure it is on
4. **Quit Myna Flow from the menu bar and open it again** — a running app does
   not pick up a new grant

**4. If it still will not stick, check whether your Mac is managed.** On a work
Mac, look at the Accessibility list: if entries say *"This setting has been
configured by a profile"*, your IT department controls this list with a
configuration profile, and a permission you add yourself can be ignored or
reset. Nothing in the app can work around that — ask whoever manages the Mac to
allow Myna Flow.

## If something goes wrong

Open Myna Flow ▸ **Audio & General** ▸ **Export diagnostics…** and send that
file. It records what happened, never what you said.

## Removing it

Drag the app to the Trash, then delete
`~/Library/Application Support/Myna Flow` to remove the history as well.
