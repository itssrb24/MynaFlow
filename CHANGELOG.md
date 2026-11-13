# Changelog

All notable changes to Myna Flow. Versions follow the app's
`CFBundleShortVersionString`.

## 1.2.1

### Fixes
- **The call can hear you again while meeting notes record.** Apple's voice
  processing silences the microphone for every other app while it runs; meeting
  notes no longer use it, and dictation skips it whenever another app is using
  the mic.
- **Summaries work in the downloaded app.** The self-signed release could not
  start the local language model (macOS refused its bundled libraries), so
  meeting summaries failed and dictation cleanup fell back silently.
- **No more echo lines.** On speakers, the call heard back through your mic no
  longer shows up as "You" in the transcript.
- **Dictation never vanishes.** Dictating while a file list, button or menu has
  focus copies the text to the clipboard and says so, instead of reporting it
  inserted.

### Improvements
- **Meetings open on their own page**, with Summary and Transcript tabs. The
  transcript reads as speaker turns, with find (⌘F, ⌘G) and a You/Others filter.
- **Notes started by hand take the calendar meeting's name** when one is in
  progress.
- **A smaller, quieter pill**: a slim capsule with the orb and a timer while you
  talk, one word while it works.
- **The meeting prompt appears top right**, where notifications do.

## 1.2.0

### Meeting notes
- **Start Notes / Stop & Summarize** from the menu bar or the new Meetings
  page. Your mic is recorded as "You" and what the Mac plays as "Others".
- Audio is transcribed on this Mac in 30-second chunks, each deleted as soon as
  it is transcribed, on every path including cancel, failure and quit.
- Key points and action items from the local language model; without a model
  the transcript is saved with a note.
- Search, Markdown export and copy, delete. Quitting mid-meeting saves the
  transcript so far; a meeting that can't be saved is written to
  `Recovered Meetings` instead of being lost.
- Survives headphones or AirPods connecting mid-call and sleep/wake; the
  dictation shortcut is paused while a meeting records.

### Meeting detection
- Optional prompts when a calendar meeting is about to start, or when a meeting
  app or browser starts using the mic. Only ever a prompt: recording starts on
  your click. A muted call is not mistaken for an ended one.
- Calendars are read from the Mac's own store (Google, Outlook, iCloud accounts
  added in System Settings); choose which calendars count.

### Permissions
- New, optional, and only asked when used: **System Audio Recording** (meeting
  notes) and **Calendar** (calendar prompts). Still no network use: the `lsof`
  check holds while recording.

### Known limits
- Call-join and call-ended prompts have been unit-tested but not yet exercised
  on a live call.
- Restarting capture when the audio output changes mid-meeting (headphones,
  AirPods) is built but not yet exercised live.
- Not notarized, as before: first launch needs right-click ▸ Open.
