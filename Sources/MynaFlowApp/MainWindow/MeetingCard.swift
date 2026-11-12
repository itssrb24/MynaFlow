import MynaFlowCore
import SwiftUI

/// One saved meeting. Collapsed: title, when, how long, and the first few
/// key points. Expanded: every key point, the action items and the
/// labelled transcript.
struct MeetingCard: View {
  let meeting: MeetingRecord
  let isExpanded: Bool
  let toggle: () -> Void
  let export: () -> Void
  let copy: () -> Void
  let delete: () -> Void

  private static let collapsedKeyPoints = 3

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      header
      if let summary = meeting.summary {
        let points =
          isExpanded ? summary.keyPoints : Array(summary.keyPoints.prefix(Self.collapsedKeyPoints))
        bullets("Key points", points, symbol: nil)
        if isExpanded { bullets("Action items", summary.actionItems, symbol: "arrow.right") }
      } else if let note = meeting.summaryNote {
        Label(note, systemImage: "text.bubble")
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textSecondary)
      }
      if isExpanded {
        SectionLabel(text: "Transcript")
        MeetingTranscriptView(segments: meeting.segments)
      }
    }
    .raised()
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
      VStack(alignment: .leading, spacing: 3) {
        Text(meeting.eventTitle ?? "Meeting")
          .font(Theme.Fonts.title)
          .foregroundStyle(Theme.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(meta)
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textSecondary)
      }
      Spacer()
      Button(isExpanded ? "Show less" : "Show all", action: toggle)
        .buttonStyle(NeuButtonStyle())
        .accessibilityHint(isExpanded ? "Hides the transcript" : "Shows action items and the transcript")
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

  /// "Nov 12, 9:30 AM · 42 min · 3 action items"
  private var meta: String {
    var parts = [
      meeting.startedAt.formatted(date: .abbreviated, time: .shortened),
      Self.duration(meeting.durationSeconds),
    ]
    if let count = meeting.summary?.actionItems.count, count > 0 {
      parts.append(count == 1 ? "1 action item" : "\(count) action items")
    }
    return parts.joined(separator: " · ")
  }

  static func duration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if seconds < 60 { return "\(Int(seconds)) s" }
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) h \(minutes % 60) min"
  }

  /// A labelled list, or nothing at all when it is empty.
  @ViewBuilder
  private func bullets(_ title: String, _ items: [String], symbol: String?) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
        SectionLabel(text: title)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            if let symbol {
              Image(systemName: symbol)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)
            } else {
              Circle().fill(Theme.Colors.accent).frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                .accessibilityHidden(true)
            }
            Text(item)
              .font(Theme.Fonts.body)
              .foregroundStyle(Theme.Colors.textPrimary)
              .textSelection(.enabled)
          }
        }
      }
    }
  }
}
