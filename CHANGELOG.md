# Changelog

All notable changes to Myna Flow. Versions follow the app's
`CFBundleShortVersionString`.

## 1.5.0

### Notes and flags during a meeting
- **Jot a note while recording** — in the field on the Meetings page, or from
  the menu bar with **Add Meeting Note…**. Notes are stamped with the meeting's
  time, appear in the transcript where you wrote them, are listed as **Your
  notes** under the summary and in Markdown export, and the summary is told
  about them.
- **Flag a moment:** **Flag moment** on the Meetings page, **Flag This Moment**
  in the menu bar, or a hotkey you choose (Hotkeys ▸ Flag meeting moment). It
  marks the 40 seconds before it as important, and the summary makes sure to
  cover them.

### Fix a line, and it's learned
- Click the pencil beside a transcript line to fix it. Names you correct are
  added to your vocabulary, so they're heard right next time, and the fix is
  suggested on the Learning page as a replacement rule.
- Approved replacement rules now apply to meeting transcripts too, not only to
  dictation.

### Recognise voices across meetings (opt-in, off by default)
- Turn on **Recognise voices across meetings** in the Separate speakers card.
  When you name a speaker, Myna Flow keeps a voice profile — numbers, not
  audio — for that person. In later meetings a confident match is named for
  you; a weaker one is suggested ("Sounds like …").
- A speaker whose voice looks like two people mixed together is never learned
  or auto-named. Renaming a speaker moves what was learned to the right
  person. **Forget all…** deletes every voice profile.

### Fixes
- Speaker changes in short back-and-forth exchanges are no longer merged into
  one line.

### Known limits
- Very similar voices (for example two synthetic voices) can be heard as one
  speaker; recognition then stays off for that speaker rather than guess.

## 1.4.0

### Meetings that know their calendar invite
- **The invite travels with the meeting:** attendees, organizer, the agenda
  (the invite's notes without the video-call footer) and the recurring series.
  The meeting page shows who was invited and the agenda; a meeting recorded
  without one can be linked to a calendar event afterwards. Notes started by
  hand find the meeting in progress even with calendar prompts off.
- **Transcription knows the names:** the speech engine listens for the people
  on the invite, your vocabulary, and names in the invite; tiny misspellings
  of those names are corrected; words invented over near-silence are dropped.
- **Better summaries:** an overview, decisions, key points and action items as
  "Owner — task" — owners are never invented. The summary knows the title,
  attendees, agenda, speaker names and what was still open from the last
  meeting in the series. The meeting type (1:1, standup, planning, review,
  client, interview) is read from the invite and tunes the summary; change it
  to rewrite. **Update summary** rewrites from the saved transcript after you
  name speakers.
- **Name speakers from the invite:** a speaker's menu suggests the people on
  the invite first, then names from the last meeting in the series; search
  people you've met; "Same person as…" merges a speaker split in two. Names
  you confirm are learned as vocabulary.

### Fixes
- Teams dial-in footers are not mistaken for an agenda; directory names like
  "Rivera, Ana" read "Ana Rivera".

## 1.3.0

### New
- **Separate speakers in meeting notes.** Install it once (about 14 MB) from the
  Meetings page and **Others** is split into **Speaker 1, 2, …**, each in its own
  colour, with a filter per speaker. Click a speaker to name them for that
  meeting; names appear in the transcript and in Markdown export. It runs on
  this Mac, on each 30-second chunk just before that chunk is deleted, so audio
  is still never kept. A speaker keeps the same number for the whole meeting.
- Parakeet now reports when each word was spoken, so a chunk is split mid-way
  when the speaker changes.

### Known limits
- Speakers are told apart per 30-second chunk, so the first minute (while the
  voices are new) and chunk edges are the least accurate. Overlapping speech is
  given to one speaker. With the Apple Speech fallback, a chunk goes whole to the
  speaker heard most.

## 1.2.2

### Changes
- **New app ID: `app.mynaflow.MynaFlow`** (was `com.itssrb24.MynaFlow`), and the
  copyright now reads "Myna Flow contributors". **After updating, grant
  Accessibility and Input Monitoring once more**: in System Settings ▸ Privacy &
  Security, remove the old Myna Flow entry with **−**, then add the app with
  **+**. History, meetings and settings carry over.
- **Polish every dictation** (Styles page, off by default): pick a style and
  each dictation is rewritten by the local model before it's typed. If the
  model is missing or fails, the cleaned text is typed instead.
- **Style shortcuts are recorded on the style** (Styles and Hotkeys pages); no
  more numbered slots.

### Fixes
- Switching the speech engine or editing vocabulary no longer resets the
  terminal-period and paste-when-unseen settings until relaunch.

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
