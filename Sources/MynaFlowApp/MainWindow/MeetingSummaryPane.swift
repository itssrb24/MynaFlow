import MynaFlowCore
import SwiftUI

/// The summary tab: key points as an easy-reading list, action items set
/// apart as the to-dos, or — with no summary — why, and a way to the
/// transcript.
struct MeetingSummaryPane: View {
  let meeting: MeetingRecord
  /// Rewriting the summary right now.
  var isUpdating = false
  /// Rewrite the summary, optionally as another meeting type.
  var update: (MeetingType?) -> Void = { _ in }
  let showTranscript: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
      if let agenda = meeting.context?.agenda {
        DisclosureGroup {
          Text(agenda)
            .font(Theme.Fonts.body)
            .lineSpacing(3)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.top, Theme.Spacing.xs)
        } label: {
          SectionLabel(text: "Agenda from the invite")
        }
        .tint(Theme.Colors.textSecondary)
        .inset(padding: Theme.Spacing.md)
      }
      if !meeting.segments.isEmpty { toolbar }
      if let summary = meeting.summary {
        if let overview = summary.overview {
          Text(overview)
            .font(.system(size: 15, weight: .regular))
            .lineSpacing(Theme.Fonts.readingLineSpacing)
            .foregroundStyle(Theme.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        if summary.keyPoints.isEmpty && summary.actionItems.isEmpty && summary.decisions.isEmpty
          && summary.overview == nil
        {
          missing("The model found nothing to summarize in this meeting.")
        }
        if !summary.actionItems.isEmpty { actionItems(summary.actionItems) }
        if !summary.decisions.isEmpty { decisions(summary.decisions) }
        if !summary.keyPoints.isEmpty { keyPoints(summary.keyPoints) }
      } else {
        missing(meeting.summaryNote ?? "This meeting has no summary.")
      }
    }
  }

  /// The meeting type (changing it rewrites the summary) and Update
  /// summary — prominent, with a reason, when names or the invite changed.
  private var toolbar: some View {
    HStack(spacing: Theme.Spacing.sm) {
      Menu {
        ForEach(MeetingType.allCases, id: \.self) { type in
          Button(type.displayName) { update(type) }
        }
      } label: {
        Label(
          (meeting.meetingType ?? .general).displayName,
          systemImage: "square.grid.2x2")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textSecondary)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("The kind of meeting the summary is written for — change it to rewrite the summary")
      if meeting.isSummaryStale {
        Text("Written before your latest speaker names")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.warning)
      }
      Spacer()
      if isUpdating {
        ProgressView().controlSize(.small)
        Text("Rewriting…").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
      } else {
        Button(meeting.summary == nil ? "Summarize" : "Update summary") { update(nil) }
          .buttonStyle(NeuButtonStyle(prominent: meeting.isSummaryStale))
          .help("Rewrites the summary from the saved transcript, with the current names and invite")
      }
    }
  }

  private func decisions(_ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      SectionLabel(text: "Decisions")
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
          Image(systemName: "checkmark.seal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Colors.success)
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
