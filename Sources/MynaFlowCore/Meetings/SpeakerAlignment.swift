import Foundation

/// Tells the voices in an "Others" chunk apart. One instance serves one
/// meeting, so the same voice keeps the same ID from chunk to chunk. Reads
/// the chunk file only; deleting it stays the session's job.
public protocol SpeakerDiarizing: Sendable {
  func diarize(audio: URL) async throws -> [SpeakerTurn]
}

/// One voice the diarizer heard in a chunk, in seconds from the chunk start.
/// `speaker` is the diarizer's own ID, stable across a meeting.
public struct SpeakerTurn: Equatable, Sendable {
  public let speaker: String
  public let start: Double
  public let end: Double

  public init(speaker: String, start: Double, end: Double) {
    self.speaker = speaker
    self.start = start
    self.end = end
  }
}

/// A stretch of a chunk's text with the speaker who said it (nil: unknown).
public struct SpeakerPiece: Equatable, Sendable {
  public let text: String
  /// Seconds from the chunk start.
  public let start: Double
  public let speaker: String?

  public init(text: String, start: Double, speaker: String?) {
    self.text = text
    self.start = start
    self.speaker = speaker
  }
}

/// Splits one transcribed "Others" chunk between the speakers the diarizer
/// heard in it. Ported from the user's Myna app (SegmentSplitter), reduced to
/// a single chunk: each word takes the turn covering its midpoint, uncovered
/// words inherit the speaker before them, and any stretch under a second is
/// folded into a neighbour — one stray word at a boundary is far more often
/// timing error than a one-word interjection.
public enum SpeakerAlignment {
  public static let minPieceSeconds = 1.0

  public static func pieces(
    text: String, words: [TimedWord]?, duration: Double, turns: [SpeakerTurn]
  ) -> [SpeakerPiece] {
    guard !turns.isEmpty else { return [SpeakerPiece(text: text, start: 0, speaker: nil)] }
    guard let words, words.count >= 2, let labels = labels(for: words, turns: turns) else {
      return [SpeakerPiece(text: text, start: 0, speaker: mostHeard(turns, duration: duration))]
    }
    let groups = coalesce(merge(groups(labels), words: words))
    // One speaker for the whole chunk: keep the engine's own text, which
    // vocabulary rescoring may have improved beyond the raw word timings.
    guard groups.count > 1 else {
      return [SpeakerPiece(text: text, start: 0, speaker: groups[0].label)]
    }
    return groups.map { group in
      let slice = words[group.range]
      return SpeakerPiece(
        text: slice.map(\.text).joined(separator: " "), start: slice.first!.start,
        speaker: group.label)
    }
  }

  /// The speaker with the most time in the chunk.
  private static func mostHeard(_ turns: [SpeakerTurn], duration: Double) -> String? {
    var seconds: [String: Double] = [:]
    for turn in turns {
      seconds[turn.speaker, default: 0] += max(0, min(turn.end, duration) - max(turn.start, 0))
    }
    return seconds.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
  }

  /// One speaker per word, or nil when no word falls inside any turn.
  private static func labels(for words: [TimedWord], turns: [SpeakerTurn]) -> [String]? {
    let covered: [String?] = words.map { word in
      turns.filter { $0.start <= word.midpoint && word.midpoint < $0.end }
        .min(by: precedes)?.speaker
    }
    guard let first = covered.compactMap({ $0 }).first else { return nil }
    var filled: [String] = []
    for label in covered { filled.append(label ?? filled.last ?? first) }
    return filled
  }

  /// Overlapping turns must resolve the same way whatever order they came in.
  private static func precedes(_ a: SpeakerTurn, _ b: SpeakerTurn) -> Bool {
    (a.start, a.end, a.speaker) < (b.start, b.end, b.speaker)
  }

  private struct Group {
    let range: Range<Int>
    let label: String
  }

  private static func groups(_ labels: [String]) -> [Group] {
    var result: [Group] = []
    var start = 0
    for i in 1..<labels.count where labels[i] != labels[i - 1] {
      result.append(Group(range: start..<i, label: labels[start]))
      start = i
    }
    result.append(Group(range: start..<labels.count, label: labels[start]))
    return result
  }

  /// Folds every group under a second into its predecessor (the first into
  /// its successor), keeping the neighbour's label.
  private static func merge(_ groups: [Group], words: [TimedWord]) -> [Group] {
    var current = groups
    while current.count > 1 {
      let seconds = current.map { words[$0.range].reduce(0) { $0 + $1.duration } }
      guard let short = seconds.firstIndex(where: { $0 < minPieceSeconds }) else { break }
      let target = short == 0 ? 1 : short - 1
      let (lo, hi) = (min(short, target), max(short, target))
      let merged = Group(
        range: current[lo].range.lowerBound..<current[hi].range.upperBound,
        label: current[target].label)
      current = Array(current[..<lo]) + [merged] + Array(current[(hi + 1)...])
    }
    return current
  }

  private static func coalesce(_ groups: [Group]) -> [Group] {
    groups.reduce(into: [Group]()) { result, group in
      if let last = result.last, last.label == group.label {
        result[result.count - 1] = Group(
          range: last.range.lowerBound..<group.range.upperBound, label: last.label)
      } else {
        result.append(group)
      }
    }
  }
}

/// "Speaker 1, 2, …" in order of first appearance, for one meeting.
public struct SpeakerNumbering: Sendable {
  private var numbers: [String: Int] = [:]

  public init() {}

  public mutating func number(for speaker: String) -> Int {
    if let existing = numbers[speaker] { return existing }
    let next = numbers.count + 1
    numbers[speaker] = next
    return next
  }
}
