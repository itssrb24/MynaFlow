# Installing Myna Flow

## Before you start

**You need macOS 26 or later.** Apple menu ▸ About This Mac tells you which
version you have. On anything older this app will not run at all.

## Install

1. Unzip **Myna Flow.zip**.
2. Drag **Myna Flow** into your **Applications** folder.
3. **Right-click** (or Control-click) the app and choose **Open**.
4. macOS says it cannot verify the developer. Click **Open**.

Step 3 matters. Double-clicking the first time gives you a dialog with no way
forward; right-click ▸ Open is the one that offers the Open button. You only
have to do it once — after that it launches normally.

### Why the warning appears

Apple charges $99 a year for the certificate that removes it. This app is
signed, but not with that certificate, so macOS tells you it could not verify
who made it. The warning is about who paid Apple, not about what the app does.

Do not run any `sudo` or `xattr` command you find online to silence warnings
like this. That habit is exactly what malware relies on. Right-click ▸ Open is
the button Apple provides for this, and it is enough.

## First run

Myna Flow lives in the menu bar and has no Dock icon. It walks you through:

1. **Microphone** — so it can hear you.
2. **Accessibility** — so it can type into other apps. macOS opens System
   Settings; switch Myna Flow on, then come back.
3. A first dictation, to prove it works.

If the shortcut does nothing right after granting Accessibility, quit Myna Flow
from the menu bar and open it again.

## Using it

- **Hold ⌘⇧Space**, talk, let go. The text appears where your cursor is.
- **⌘⌃Space** starts and stops instead, for longer stretches.
- **Esc** cancels.
- Everything you dictate is kept in History, on your Mac, and can be deleted
  from there.

## If something goes wrong

Open Myna Flow ▸ **Audio & General** ▸ **Export diagnostics…** and send that
file. It records what happened, never what you said.

## Removing it

Drag the app to the Trash, then delete
`~/Library/Application Support/Myna Flow` to remove the history as well.
