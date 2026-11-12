import MynaFlowCore
import SwiftUI

/// A meeting transcript as rows: time, who spoke, what they said. "You" and
/// "Others" read apart at a glance, and a long meeting scrolls inside the
/// card instead of stretching the page.
struct MeetingTranscriptView: View {
  let segments: [MeetingSegment]
  private static let maxHeight: CGFloat = 360

  var body: some View {
    if segments.isEmpty {
      Text("Nothing was transcribed.")
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Colors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inset()
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
          ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            row(segment)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: Self.maxHeight)
      .inset()
      .textSelection(.enabled)
    }
  }

  private func row(_ segment: MeetingSegment) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
      Text(MeetingTranscript.timestamp(segment.startSeconds))
        .font(Theme.Fonts.mono)
        .foregroundStyle(Theme.Colors.textTertiary)
        .monospacedDigit()
      SpeakerChip(channel: segment.channel)
      Text(segment.text)
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Colors.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

/// "You" in the accent, "Others" neutral — the two voices of a call.
struct SpeakerChip: View {
  let channel: MeetingChannel

  var body: some View {
    let isYou = channel == .you
    Text(channel.label)
      .font(Theme.Fonts.caption)
      .foregroundStyle(isYou ? Theme.Colors.accent : Theme.Colors.textSecondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(
        Capsule().fill(isYou ? Theme.Colors.accentMuted : Theme.Colors.surface))
      .overlay(Capsule().strokeBorder(Theme.Colors.hairline))
      .frame(width: 58, alignment: .leading)
  }
}
