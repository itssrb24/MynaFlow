# Changelog

All notable changes to Myna Flow. Versions follow the app's
`CFBundleShortVersionString`.

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
