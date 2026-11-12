import MynaFlowCore
import SwiftUI

/// The summary tab: key points as an easy-reading list, action items set
/// apart as the to-dos, or — with no summary — why, and a way to the
/// transcript.
struct MeetingSummaryPane: View {
  let meeting: MeetingRecord
  let showTranscript: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
      if let summary = meeting.summary {
        if summary.keyPoints.isEmpty && summary.actionItems.isEmpty {
          missing("The model found nothing to summarize in this meeting.")
        }
        if !summary.actionItems.isEmpty { actionItems(summary.actionItems) }
        if !summary.keyPoints.isEmpty { keyPoints(summary.keyPoints) }
      } else {
        missing(meeting.summaryNote ?? "This meeting has no summary.")
      }
    }
  }

  private func keyPoints(_ points: [String]) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      SectionLabel(text: "Key points")
      ForEach(Array(points.enumerated()), id: \.offset) { _, point in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
          Circle()
            .fill(Theme.Colors.accent)
            .frame(width: 6, height: 6)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            .accessibilityHidden(true)
          Text(point)
            .font(Theme.Fonts.reading)
            .lineSpacing(Theme.Fonts.readingLineSpacing)
            .foregroundStyle(Theme.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
  }

  /// To-dos come first and sit on their own raised panel: they're what a
  /// reader comes back for.
  private func actionItems(_ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.sm) {
        SectionLabel(text: "Action items")
        Text("\(items.count)")
          .font(Theme.Fonts.caption)
          .monospacedDigit()
          .foregroundStyle(Theme.Colors.accent)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(Theme.Colors.accentMuted))
          .accessibilityLabel("\(items.count) items")
      }
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
          Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.Colors.accent)
            .accessibilityHidden(true)
          Text(item)
            .font(Theme.Fonts.reading)
            .lineSpacing(Theme.Fonts.readingLineSpacing)
            .foregroundStyle(Theme.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .raised()
  }

  private func missing(_ note: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(alignment: .top, spacing: Theme.Spacing.sm) {
        Image(systemName: "text.bubble")
          .foregroundStyle(Theme.Colors.textTertiary)
          .accessibilityHidden(true)
        Text(note)
          .font(Theme.Fonts.reading)
          .lineSpacing(Theme.Fonts.readingLineSpacing)
          .foregroundStyle(Theme.Colors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if !meeting.segments.isEmpty {
        Button("Read the transcript", action: showTranscript)
          .buttonStyle(NeuButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .inset(padding: Theme.Spacing.lg)
  }
}
