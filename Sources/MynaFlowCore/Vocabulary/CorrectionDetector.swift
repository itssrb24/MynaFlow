import Foundation

public struct CorrectionPair: Equatable, Sendable {
  public let before: String
  public let after: String

  public init(before: String, after: String) {
    self.before = before
    self.after = after
  }
}

/// Finds what the user changed in text shortly after it was inserted. Pure
/// diff over the field's value before and after, restricted to the region
/// the dictation put there, expanded to word boundaries.
public enum CorrectionDetector {
  public static func detect(before: String, after: String, inserted: String) -> CorrectionPair? {
    guard before != after, !after.isEmpty, !inserted.isEmpty,
      let insertedRange = before.range(of: inserted)
    else { return nil }

    let beforeChars = Array(before)
    let afterChars = Array(after)
    var prefix = 0
    while prefix < beforeChars.count, prefix < afterChars.count,
      beforeChars[prefix] == afterChars[prefix]
    {
      prefix += 1
    }
    var suffix = 0
    while suffix < beforeChars.count - prefix, suffix < afterChars.count - prefix,
      beforeChars[beforeChars.count - 1 - suffix] == afterChars[afterChars.count - 1 - suffix]
    {
      suffix += 1
    }

    // Expand to word boundaries so "kubernetes"→"Kubernetes" reports the
    // whole word, not one character.
    while prefix > 0, !beforeChars[prefix - 1].isWhitespace { prefix -= 1 }
    while suffix > 0, !beforeChars[beforeChars.count - suffix].isWhitespace { suffix -= 1 }

    let beforeRegion = String(beforeChars[prefix..<(beforeChars.count - suffix)])
    let afterRegion = String(afterChars[prefix..<(afterChars.count - suffix)])
    guard !afterRegion.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

    // The change must touch the inserted text.
    let insertedStart = before.distance(from: before.startIndex, to: insertedRange.lowerBound)
    let insertedEnd = before.distance(from: before.startIndex, to: insertedRange.upperBound)
    let changeStart = prefix
    let changeEnd = beforeChars.count - suffix
    guard changeStart < insertedEnd, changeEnd > insertedStart else { return nil }

    return CorrectionPair(
      before: beforeRegion.trimmingCharacters(in: .whitespaces),
      after: afterRegion.trimmingCharacters(in: .whitespaces))
  }

  /// Vocabulary candidates: the corrected words. Adjacent changed words form
  /// one phrase ("John Smyth"); a length-changing edit is one candidate.
  public static func candidateTerms(from pair: CorrectionPair) -> [String] {
    let beforeWords = words(pair.before)
    let afterWords = words(pair.after)
    guard beforeWords.count == afterWords.count else {
      let whole = pair.after.trimmingCharacters(in: .whitespacesAndNewlines)
      return whole.isEmpty ? [] : [whole]
    }
    var candidates: [String] = []
    var current: [String] = []
    for (before, after) in zip(beforeWords, afterWords) {
      if before != after {
        current.append(after)
      } else if !current.isEmpty {
        candidates.append(current.joined(separator: " "))
        current = []
      }
    }
    if !current.isEmpty { candidates.append(current.joined(separator: " ")) }
    return candidates
  }

  private static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map {
      String($0).trimmingCharacters(in: .punctuationCharacters)
    }
  }
}
