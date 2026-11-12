import MynaFlowCore
import SwiftUI

/// One saved meeting in the list: name, when, how long, and a one-line
/// preview. Clicking it opens the meeting on its own page.
struct MeetingRow: View {
  let meeting: MeetingRecord
  let open: () -> Void
  let export: () -> Void
  let copy: () -> Void
  let delete: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(alignment: .center, spacing: Theme.Spacing.md) {
      Button(action: open) {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
          VStack(alignment: .leading, spacing: 4) {
            Text(meeting.displayTitle)
              .font(Theme.Fonts.title)
              .foregroundStyle(Theme.Colors.textPrimary)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(meeting.metaLine)
              .font(Theme.Fonts.caption)
              .foregroundStyle(Theme.Colors.textSecondary)
            if let preview = meeting.preview {
              Text(preview)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .padding(.top, 2)
            }
          }
          Spacer(minLength: Theme.Spacing.sm)
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering ? Theme.Colors.accent : Theme.Colors.textTertiary)
            .offset(x: hovering ? 2 : 0)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(meeting.displayTitle), \(meeting.metaLine)")
      .accessibilityHint("Opens the summary and transcript")
      MeetingActionsMenu(export: export, copy: copy, delete: delete)
    }
    .raised(padding: Theme.Spacing.md + 2)
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        .strokeBorder(hovering ? Theme.Colors.accent.opacity(0.35) : .clear, lineWidth: 1))
    .scaleEffect(hovering ? 1.004 : 1)
    .animation(.easeOut(duration: Theme.Motion.fast), value: hovering)
    .onHover { hovering = $0 }
  }
}

/// Export, copy, delete — the same menu on a list row and a meeting's page.
struct MeetingActionsMenu: View {
  let export: () -> Void
  let copy: () -> Void
  let delete: () -> Void

  var body: some View {
    Menu {
      Button("Export as Markdown…", action: export)
      Button("Copy as Markdown", action: copy)
      Divider()
      Button("Delete…", role: .destructive, action: delete)
    } label: {
      Label("Meeting actions", systemImage: "ellipsis.circle")
        .labelStyle(.iconOnly)
        .foregroundStyle(Theme.Colors.textSecondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Export, copy or delete")
  }
}

extension MeetingRecord {
  var displayTitle: String { eventTitle ?? "Meeting" }

  /// "Nov 12, 2026 at 9:30 AM · 42 min · 3 action items"
  var metaLine: String {
    var parts = [
      startedAt.formatted(date: .abbreviated, time: .shortened),
      Self.durationLabel(durationSeconds),
    ]
    if let count = summary?.actionItems.count, count > 0 {
      parts.append(count == 1 ? "1 action item" : "\(count) action items")
    }
    return parts.joined(separator: " · ")
  }

  /// The first key point, else the first words said; the "no summary" note
  /// is the same on every row, so it only shows when nothing was said.
  var preview: String? {
    summary?.keyPoints.first
      ?? MeetingTranscript.turns(segments).first?.text
      ?? summaryNote
  }

  static func durationLabel(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if seconds < 60 { return "\(Int(seconds)) s" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) h \(minutes % 60) min"
  }
}
