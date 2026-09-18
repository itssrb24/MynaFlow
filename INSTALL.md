# Installing Myna Flow

**You need macOS 26 or later.** Apple menu ▸ About This Mac tells you which
version you have. On anything older this app will not run at all — dictation
uses a system component that only exists from macOS 26.

There are two ways in. Pick one.

---

## Option A — download it (easiest)

1. Download **MynaFlow-1.0.0.zip** and unzip it.
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

## If something goes wrong

Open Myna Flow ▸ **Audio & General** ▸ **Export diagnostics…** and send that
file. It records what happened, never what you said.

## Removing it

Drag the app to the Trash, then delete
`~/Library/Application Support/Myna Flow` to remove the history as well.
