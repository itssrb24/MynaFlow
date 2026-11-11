import Foundation

/// Which side of the call a stream carries. Channel labels stand in for
/// diarization, which is out of scope: the microphone is "You", whatever the
/// Mac plays is "Others".
public enum MeetingChannel: String, Codable, CaseIterable, Sendable {
  case you
  case others

  public var label: String {
    switch self {
    case .you: "You"
    case .others: "Others"
    }
  }

  /// Tie-break when both channels start a chunk at the same instant.
  var sortOrder: Int {
    switch self {
    case .you: 0
    case .others: 1
    }
  }
}

/// One transcribed chunk of one channel, positioned by audio time since the
/// meeting started.
public struct MeetingSegment: Codable, Equatable, Sendable {
  public let channel: MeetingChannel
  public let startSeconds: Double
  public let text: String

  public init(channel: MeetingChannel, startSeconds: Double, text: String) {
    self.channel = channel
    self.startSeconds = startSeconds
    self.text = text
  }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
  public let keyPoints: [String]
  public let actionItems: [String]

  public init(keyPoints: [String], actionItems: [String]) {
    self.keyPoints = keyPoints
    self.actionItems = actionItems
  }
}

/// A finished meeting as stored. Audio is never part of it.
public struct MeetingRecord: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let startedAt: Date
  public let durationSeconds: Double
  public let segments: [MeetingSegment]
  public let summary: MeetingSummary?
  /// Why there is no summary (no model, model failed), shown in its place.
  public let summaryNote: String?

  public init(
    id: UUID = UUID(),
    startedAt: Date,
    durationSeconds: Double,
    segments: [MeetingSegment],
    summary: MeetingSummary?,
    summaryNote: String?
  ) {
    self.id = id
    self.startedAt = startedAt
    self.durationSeconds = durationSeconds
    self.segments = segments
    self.summary = summary
    self.summaryNote = summaryNote
  }

  public var title: String {
    "Meeting — " + startedAt.formatted(date: .abbreviated, time: .shortened)
  }

  public var transcriptText: String { MeetingTranscript.render(segments) }
}

public enum MeetingTranscript {
  /// Interleaves both channels by audio time. Stable: chunks of one channel
  /// keep their order, and "You" precedes "Others" when they start together.
  public static func merge(_ segments: [MeetingSegment]) -> [MeetingSegment] {
    segments.enumerated().sorted { lhs, rhs in
      let (l, r) = (lhs.element, rhs.element)
      if l.startSeconds != r.startSeconds { return l.startSeconds < r.startSeconds }
      if l.channel != r.channel { return l.channel.sortOrder < r.channel.sortOrder }
      return lhs.offset < rhs.offset
    }.map(\.element)
  }

  public static func render(_ segments: [MeetingSegment]) -> String {
    segments.map(line).joined(separator: "\n")
  }

  static func line(_ segment: MeetingSegment) -> String {
    "[\(timestamp(segment.startSeconds))] \(segment.channel.label): \(segment.text)"
  }

  public static func timestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%02d:%02d", minutes, secs)
  }
}

public enum MeetingExporter {
  public static func markdown(_ meeting: MeetingRecord) -> String {
    var sections = [
      "# \(meeting.title)",
      "Duration: \(MeetingTranscript.timestamp(meeting.durationSeconds))",
    ]
    if let summary = meeting.summary {
      sections.append("## Key points\n" + bulleted(summary.keyPoints, prefix: "- "))
      sections.append("## Action items\n" + bulleted(summary.actionItems, prefix: "- [ ] "))
    } else if let note = meeting.summaryNote {
      sections.append("> \(note)")
    }
    sections.append("## Transcript\n" + meeting.transcriptText)
    return sections.joined(separator: "\n\n") + "\n"
  }

  private static func bulleted(_ items: [String], prefix: String) -> String {
    items.isEmpty ? "_None_" : items.map { prefix + $0 }.joined(separator: "\n")
  }
}
