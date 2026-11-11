import MynaFlowCore
import SwiftUI

/// Saved meeting notes: start/stop, then each meeting's summary, action
/// items and labelled transcript, with export and delete.
struct MeetingsView: View {
  let recorder: MeetingRecorder
  @State private var expanded: UUID?
  @State private var confirmDelete: MeetingRecord?

  var body: some View {
    Page(
      title: "Meetings",
      subtitle: "Your mic is \"You\", what the Mac plays is \"Others\". Transcribed and summarized on this Mac; audio is deleted every 30 seconds."
    ) {
      recordControl
      if let notice = recorder.notice {
        Label(notice, systemImage: "info.circle")
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.warning)
      }
      if recorder.meetings.isEmpty {
        Text("No meetings yet.")
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textTertiary)
          .frame(maxWidth: .infinity, minHeight: 120)
          .inset()
      } else {
        LazyVStack(spacing: Theme.Spacing.sm) {
          ForEach(recorder.meetings) { meeting in
            MeetingCard(
              meeting: meeting,
              isExpanded: expanded == meeting.id,
              toggle: {
                withAnimation(Theme.Motion.ease) {
                  expanded = expanded == meeting.id ? nil : meeting.id
                }
              },
              export: { recorder.export(meeting) },
              copy: { recorder.copyMarkdown(meeting) },
              delete: { confirmDelete = meeting })
          }
        }
      }
    }
    .task { await recorder.refresh() }
    .confirmationDialog(
      "Delete this meeting's notes?",
      isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let meeting = confirmDelete { Task { await recorder.delete(meeting) } }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var recordControl: some View {
    HStack(spacing: Theme.Spacing.md) {
      Circle()
        .fill(recorder.isRecording ? Theme.Colors.danger : Theme.Colors.textTertiary)
        .frame(width: 10, height: 10)
      VStack(alignment: .leading, spacing: 2) {
        Text(statusTitle).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
        Text("Start and stop are always yours — nothing records on its own.")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      }
      Spacer()
      if recorder.phase == .recording || recorder.phase == .finishing {
        Button("Discard") { Task { await recorder.cancel() } }
          .buttonStyle(NeuButtonStyle(destructive: true))
      }
      Button(recorder.isRecording ? "Stop & Summarize" : "Start Meeting Notes") { recorder.toggle() }
        .buttonStyle(NeuButtonStyle(prominent: true))
        .disabled(recorder.phase == .starting || recorder.phase == .finishing)
    }
    .raised()
  }

  private var statusTitle: String {
    switch recorder.phase {
    case .idle: "Not recording"
    case .starting: "Starting…"
    case .recording: "Recording meeting…"
    case .finishing: "Transcribing the last minute and summarizing…"
    }
  }
}

private struct MeetingCard: View {
  let meeting: MeetingRecord
  let isExpanded: Bool
  let toggle: () -> Void
  let export: () -> Void
  let copy: () -> Void
  let delete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      header
      if let summary = meeting.summary {
        list("Key points", summary.keyPoints, symbol: "circle.fill")
        list("Action items", summary.actionItems, symbol: "square")
      } else if let note = meeting.summaryNote {
        Text(note).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
      }
      if isExpanded {
        SectionLabel(text: "Transcript")
        Text(meeting.transcriptText.isEmpty ? "Nothing was transcribed." : meeting.transcriptText)
          .font(Theme.Fonts.mono)
          .foregroundStyle(Theme.Colors.textPrimary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .inset()
      }
    }
    .raised()
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(meeting.title).font(Theme.Fonts.title).foregroundStyle(Theme.Colors.textPrimary)
        Text("\(MeetingTranscript.timestamp(meeting.durationSeconds)) · \(meeting.segments.count) segments")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      }
      Spacer()
      Button(isExpanded ? "Hide transcript" : "Transcript", action: toggle)
        .buttonStyle(NeuButtonStyle())
      Menu {
        Button("Export as Markdown…", action: export)
        Button("Copy as Markdown", action: copy)
        Divider()
        Button("Delete…", role: .destructive, action: delete)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }

  @ViewBuilder
  private func list(_ title: String, _ items: [String], symbol: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      SectionLabel(text: title)
      if items.isEmpty {
        Text("None").font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textTertiary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        Label {
          Text(item).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
        } icon: {
          Image(systemName: symbol).font(.system(size: 6)).foregroundStyle(Theme.Colors.accent)
        }
      }
    }
  }
}
