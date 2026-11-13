import Foundation

/// Drops "You" lines that are the call heard back through the microphone.
///
/// On a Mac's speakers the other side of the call leaks into the mic; voice
/// processing removes most of it but not all, especially in its first
/// seconds. Such a line repeats words the system-audio channel ("Others")
/// carried at the same moment. Matching word pairs rather than single words
/// keeps a real reply that happens to reuse common words.
public enum MeetingEcho {
  /// Lines shorter than this are kept: too few words to tell an echo apart.
  static let minimumWords = 3
  /// Share of a line's word pairs that must appear in the call nearby.
  static let threshold = 0.75

  /// `window` is how far apart, in seconds, a "You" chunk and an "Others"
  /// chunk may start and still overlap — the chunk length.
  public static func removeEchoes(_ segments: [MeetingSegment], window: Double)
    -> [MeetingSegment]
  {
    let others = segments.filter { $0.channel == .others }
    return segments.filter { segment in
      guard segment.channel == .you else { return true }
      return !isEcho(segment, of: others, window: window)
    }
  }

  private static func isEcho(_ line: MeetingSegment, of others: [MeetingSegment], window: Double)
    -> Bool
  {
    let words = self.words(line.text)
    guard words.count >= minimumWords else { return false }
    let nearby = others.filter { abs($0.startSeconds - line.startSeconds) <= window }
    guard !nearby.isEmpty else { return false }
    let heard = Set(nearby.flatMap { pairs(self.words($0.text)) })
    let said = pairs(words)
    let repeated = said.filter(heard.contains).count
    return Double(repeated) / Double(said.count) >= threshold
  }

  /// Lowercased words, punctuation dropped, apostrophes kept ("we've").
  static func words(_ text: String) -> [String] {
    text.lowercased()
      .replacingOccurrences(of: "\u{2019}", with: "'")
      .split { !($0.isLetter || $0.isNumber || $0 == "'") }
      .map(String.init)
  }

  private static func pairs(_ words: [String]) -> [String] {
    zip(words, words.dropFirst()).map { "\($0) \($1)" }
  }
}
