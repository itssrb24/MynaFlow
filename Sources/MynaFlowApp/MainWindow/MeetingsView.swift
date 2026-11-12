import MynaFlowCore
import SwiftUI

/// Meeting notes: start and stop, detection settings, and every saved
/// meeting — searchable, with its summary, action items and transcript.
struct MeetingsView: View {
  let recorder: MeetingRecorder
  let detection: MeetingDetectionController
  @State private var expanded: UUID?
  @State private var confirmDelete: MeetingRecord?
  @State private var searchText = ""

  var body: some View {
    Page(
      title: "Meetings",
      subtitle: "Your mic is \"You\", what the Mac plays is \"Others\". Transcribed and summarized on this Mac; audio is deleted as it's transcribed."
    ) {
      RecordControl(recorder: recorder)
      MeetingDetectionCard(detection: detection)
      if !recorder.meetings.isEmpty { searchField }
      list
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
    } message: {
      Text("The summary and transcript are removed from this Mac. This can't be undone.")
    }
  }

  private var searchField: some View {
    HStack(spacing: Theme.Spacing.sm) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Theme.Colors.textTertiary)
        .accessibilityHidden(true)
      TextField("Search meetings", text: $searchText)
        .textFieldStyle(.plain)
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Colors.textPrimary)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Label("Clear search", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.textTertiary)
      }
    }
    .inset(padding: Theme.Spacing.sm + 2)
    .frame(maxWidth: 360)
  }

  @ViewBuilder
  private var list: some View {
    let shown = MeetingSearch.filter(recorder.meetings, query: searchText)
    if recorder.meetings.isEmpty {
      emptyState(
        symbol: "person.2.wave.2", title: "No meetings yet",
        detail: "Click Start Notes when a meeting begins, or turn on detection to be asked.")
    } else if shown.isEmpty {
      emptyState(
        symbol: "magnifyingglass", title: "No matches",
        detail: "Nothing in your meetings mentions \"\(searchText)\".")
    } else {
      LazyVStack(spacing: Theme.Spacing.md) {
        ForEach(shown) { meeting in
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

  private func emptyState(symbol: String, title: String, detail: String) -> some View {
    VStack(spacing: Theme.Spacing.sm) {
      Image(systemName: symbol)
        .font(.system(size: 26, weight: .light))
        .foregroundStyle(Theme.Colors.textTertiary)
        .accessibilityHidden(true)
      Text(title).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
      Text(detail)
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Colors.textSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: 140)
    .inset()
  }
}

/// Start / stop, what's happening now, and the latest notice.
private struct RecordControl: View {
  let recorder: MeetingRecorder

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.md) {
        statusGlyph
        VStack(alignment: .leading, spacing: 2) {
          Text(statusTitle)
            .font(Theme.Fonts.bodyStrong)
            .foregroundStyle(Theme.Colors.textPrimary)
            .monospacedDigit()
          Text("Start and stop are always yours — nothing records on its own.")
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        Spacer()
        if recorder.phase == .recording {
          Button("Discard") { Task { await recorder.cancel() } }
            .buttonStyle(NeuButtonStyle(destructive: true))
            .help("Stop and delete this meeting without saving")
        }
        Button(recorder.phase == .recording ? "Stop & Summarize" : "Start Notes") { recorder.toggle() }
          .buttonStyle(NeuButtonStyle(prominent: true))
          .disabled(recorder.phase == .starting || recorder.phase == .finishing)
          .help(recorder.phase == .finishing ? "Finishing the last meeting…" : "")
      }
      if let notice = recorder.notice { NoticeRow(notice: notice, recorder: recorder) }
    }
    .raised()
  }

  @ViewBuilder
  private var statusGlyph: some View {
    switch recorder.phase {
    case .starting, .finishing:
      ProgressView().controlSize(.small).frame(width: 10, height: 10)
    case .recording:
      Circle().fill(Theme.Colors.danger).frame(width: 10, height: 10).accessibilityHidden(true)
    case .idle:
      Circle().fill(Theme.Colors.textTertiary).frame(width: 10, height: 10).accessibilityHidden(true)
    }
  }

  private var statusTitle: String {
    switch recorder.phase {
    case .idle: "Not recording"
    case .starting: "Starting…"
    case .recording: "Recording · \(MeetingTranscript.timestamp(Double(recorder.elapsedSeconds)))"
    case .finishing: "Summarizing…"
    }
  }
}

/// A notice coloured by how serious it is, with a reveal for a recovered
/// transcript and a dismiss.
private struct NoticeRow: View {
  let notice: MeetingNotice
  let recorder: MeetingRecorder

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
      Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
      Text(notice.text)
        .font(Theme.Fonts.body)
        .foregroundStyle(notice.tone == .info ? Theme.Colors.textSecondary : color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      if let url = notice.revealURL {
        Button("Show in Finder") { recorder.reveal(url) }.buttonStyle(NeuButtonStyle())
      }
      Button {
        recorder.dismissNotice()
      } label: {
        Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.Colors.textTertiary)
    }
    .inset(padding: Theme.Spacing.sm + 2)
    .accessibilityElement(children: .contain)
  }

  private var symbol: String {
    switch notice.tone {
    case .info: "info.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    }
  }

  private var color: Color {
    switch notice.tone {
    case .info: Theme.Colors.textSecondary
    case .warning: Theme.Colors.warning
    case .error: Theme.Colors.danger
    }
  }
}
