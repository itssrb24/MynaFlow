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
  /// Which voice in "Others" said this — 1, 2, … in order of first
  /// appearance. Nil for "You", for meetings before speaker separation, and
  /// when no speaker could be told apart. Old saved segments decode as nil.
  public let speaker: Int?

  public init(channel: MeetingChannel, startSeconds: Double, text: String, speaker: Int? = nil) {
    self.channel = channel
    self.startSeconds = startSeconds
    self.text = text
    self.speaker = speaker
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
  /// The calendar event the meeting was started for, when it was.
  public let eventTitle: String?
  /// Names the user gave "Others" speakers in this meeting, by number.
  public let speakerNames: [Int: String]

  public init(
    id: UUID = UUID(),
    startedAt: Date,
    durationSeconds: Double,
    segments: [MeetingSegment],
    summary: MeetingSummary?,
    summaryNote: String?,
    eventTitle: String? = nil,
    speakerNames: [Int: String] = [:]
  ) {
    self.id = id
    self.startedAt = startedAt
    self.durationSeconds = durationSeconds
    self.segments = segments
    self.summary = summary
    self.summaryNote = summaryNote
    self.eventTitle = eventTitle
    self.speakerNames = speakerNames
  }

  /// "You", a speaker's given name, "Speaker N", or "Others".
  public func label(channel: MeetingChannel, speaker: Int?) -> String {
    MeetingTranscript.label(channel: channel, speaker: speaker, names: speakerNames)
  }

  public var title: String {
    (eventTitle ?? "Meeting") + " — " + startedAt.formatted(date: .abbreviated, time: .shortened)
  }

  public var transcriptText: String { MeetingTranscript.render(segments, names: speakerNames) }
}

/// One speaker's uninterrupted stretch: consecutive chunks of a channel read
/// as a paragraph instead of a new line every 30 seconds.
public struct MeetingTurn: Equatable, Sendable {
  public let channel: MeetingChannel
  public let startSeconds: Double
  public let text: String
  /// The "Others" speaker number, when speakers were told apart.
  public let speaker: Int?

  public init(channel: MeetingChannel, startSeconds: Double, text: String, speaker: Int? = nil) {
    self.channel = channel
    self.startSeconds = startSeconds
    self.text = text
    self.speaker = speaker
  }
}

public enum MeetingTranscript {
  /// Time-ordered turns. Blank chunks are dropped, so silence on one side
  /// never splits the other side's paragraph.
  public static func turns(_ segments: [MeetingSegment]) -> [MeetingTurn] {
    merge(segments).reduce(into: [MeetingTurn]()) { turns, segment in
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      if let last = turns.last, last.channel == segment.channel, last.speaker == segment.speaker {
        turns[turns.count - 1] = MeetingTurn(
          channel: last.channel, startSeconds: last.startSeconds, text: last.text + " " + text,
          speaker: last.speaker)
      } else {
        turns.append(
          MeetingTurn(
            channel: segment.channel, startSeconds: segment.startSeconds, text: text,
            speaker: segment.speaker))
      }
    }
  }

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

  public static func render(_ segments: [MeetingSegment], names: [Int: String] = [:]) -> String {
    segments.map { line($0, names: names) }.joined(separator: "\n")
  }

  static func line(_ segment: MeetingSegment, names: [Int: String] = [:]) -> String {
    let who = label(channel: segment.channel, speaker: segment.speaker, names: names)
    return "[\(timestamp(segment.startSeconds))] \(who): \(segment.text)"
  }

  /// "You", a speaker's given name, "Speaker N", or "Others" for a voice
  /// that wasn't told apart.
  public static func label(channel: MeetingChannel, speaker: Int?, names: [Int: String]) -> String {
    guard channel == .others, let speaker else { return channel.label }
    return names[speaker] ?? "Speaker \(speaker)"
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
