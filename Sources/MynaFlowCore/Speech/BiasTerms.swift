import Foundation

/// Builds the contextual-bias list handed to the transcriber. The list is
/// capped, so order matters: callers pass proven corrections before typed
/// vocabulary before everything else.
public enum BiasTerms {
  /// How many terms the transcriber is given. Ours, not a system limit.
  public static let limit = 100

  /// Trim, drop blanks, dedupe case-insensitively keeping the earliest (so
  /// highest-priority) position, then cut the tail at `limit`.
  public static func sanitize(_ terms: [String], limit: Int = BiasTerms.limit) -> [String] {
    guard limit > 0 else { return [] }
    var seen = Set<String>()
    var kept: [String] = []
    for term in terms {
      let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
      kept.append(trimmed)
      if kept.count == limit { break }
    }
    return kept
  }

  /// Custom vocabulary is one free-text field; users separate with either.
  public static func split(_ vocabulary: String) -> [String] {
    vocabulary
      .split(whereSeparator: { $0 == "," || $0 == "\n" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
