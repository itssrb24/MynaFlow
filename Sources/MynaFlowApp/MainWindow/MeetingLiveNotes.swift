import MynaFlowCore
import SwiftUI

/// While recording: jot a note or flag the moment just heard. Both are
/// stamped with the meeting's time and go into the summary.
struct MeetingLiveNotes: View {
  let recorder: MeetingRecorder
  @State private var draft = ""
  @FocusState private var focused: Bool

  private static let visibleNotes = 3

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.sm) {
        TextField("Add a note — it goes into the summary", text: $draft)
          .textFieldStyle(.plain)
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textPrimary)
          .focused($focused)
          .onSubmit(add)
          .inset(padding: Theme.Spacing.sm + 2)
        Button(action: recorder.flagMoment) {
          Label("Flag moment", systemImage: "flag.fill")
        }
        .buttonStyle(NeuButtonStyle())
        .help("Mark the last 40 seconds as important")
      }
      ForEach(Array(recorder.liveNotes.suffix(Self.visibleNotes).enumerated()), id: \.offset) { _, note in
        NoteMarker(note: note)
      }
    }
    .onChange(of: recorder.noteFocusRequests, initial: true) {
      if recorder.noteFocusRequests > 0 { focused = true }
    }
  }

  private func add() {
    let text = draft
    draft = ""
    Task { await recorder.addNote(text) }
  }
}

/// One note or flag, as it appears on the recording card and in the transcript.
struct NoteMarker: View {
  let note: MeetingNote

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
      Image(systemName: note.kind == .flag ? "flag.fill" : "note.text")
        .foregroundStyle(note.kind == .flag ? Theme.Colors.warning : Theme.Colors.accent)
        .accessibilityHidden(true)
      Text(MeetingTranscript.timestamp(note.seconds))
        .font(Theme.Fonts.mono)
        .monospacedDigit()
        .foregroundStyle(Theme.Colors.textTertiary)
      Text(note.text ?? "Flagged the 40 seconds before this as important")
        .font(note.kind == .flag ? Theme.Fonts.caption : Theme.Fonts.body)
        .foregroundStyle(note.kind == .flag ? Theme.Colors.textSecondary : Theme.Colors.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      note.kind == .flag
        ? "Flag at \(MeetingTranscript.timestamp(note.seconds))"
        : "Note at \(MeetingTranscript.timestamp(note.seconds)): \(note.text ?? "")")
  }
}
