import Foundation

/// Filters saved meetings by a typed query: every word must appear somewhere
/// in the meeting — its event title, key points, action items or transcript —
/// ignoring case and accents.
public enum MeetingSearch {
  public static func filter(_ meetings: [MeetingRecord], query: String) -> [MeetingRecord] {
    let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return meetings }
    return meetings.filter { meeting in
      let haystack = normalized(searchableText(meeting))
      return words.allSatisfy(haystack.contains)
    }
  }

  /// Every place `query` appears in `text`, ignoring case and accents, as
  /// ranges of `text` itself — for highlighting and counting.
  public static func matches(of query: String, in text: String) -> [Range<String.Index>] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var ranges: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while let found = text.range(
      of: needle, options: [.caseInsensitive, .diacriticInsensitive],
      range: searchStart..<text.endIndex)
    {
      ranges.append(found)
      searchStart = found.upperBound
    }
    return ranges
  }

  private static func searchableText(_ meeting: MeetingRecord) -> String {
    var fields = [meeting.eventTitle ?? ""]
    fields += meeting.summary?.keyPoints ?? []
    fields += meeting.summary?.actionItems ?? []
    fields += meeting.segments.map(\.text)
    return fields.joined(separator: "\n")
  }

  private static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
