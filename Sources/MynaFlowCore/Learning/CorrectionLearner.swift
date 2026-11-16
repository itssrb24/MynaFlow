import Foundation

/// A word the engine got wrong and the word the user typed instead.
public struct LearnedSubstitution: Equatable, Sendable {
  public let wrong: String
  public let right: String

  public init(wrong: String, right: String) {
    self.wrong = wrong
    self.right = right
  }
}

/// Learns from a hand-edited transcript line (ported from Myna). Every manual
/// fix is ground truth: what the user typed is a word this engine gets wrong
/// and this user actually hears. Deliberately narrow — only name-shaped
/// substitutions are learned, so ordinary rewording never becomes a rule.
public enum CorrectionLearner {
  public static func learn(original: String, edited: String) -> [LearnedSubstitution] {
    let before = original.split(whereSeparator: \.isWhitespace).map(String.init)
    let after = edited.split(whereSeparator: \.isWhitespace).map(String.init)
    return substitutions(from: before, to: after).compactMap { wrong, right in
      let wrongCore = wrong.trimmingCharacters(in: .punctuationCharacters)
      let rightCore = right.trimmingCharacters(in: .punctuationCharacters)
      return isTeachable(wrong: wrongCore, right: rightCore)
        ? LearnedSubstitution(wrong: wrongCore, right: rightCore) : nil
    }
  }

  /// Worth remembering only when the replacement looks like a name or
  /// jargon: capitalized, distinctive, and not ordinary speech on *either*
  /// side — learning "There" → "Thera" would corrupt every later sentence.
  private static func isTeachable(wrong: String, right: String) -> Bool {
    wrong.count >= 3 && right.count >= 3
      && wrong.allSatisfy(\.isLetter) && right.allSatisfy(\.isLetter)
      && right.first?.isUppercase == true
      // A pure capitalization fix teaches the engine nothing.
      && wrong.lowercased() != right.lowercased()
      && !NameCorrector.commonWords.contains(wrong.lowercased())
      && !NameCorrector.commonWords.contains(right.lowercased())
  }

  /// Word-level diff reduced to substitutions. Removed and added runs at the
  /// same place are zipped pairwise, so "Flewid Audio" → "FluidAudio" still
  /// teaches.
  private static func substitutions(from before: [String], to after: [String])
    -> [(String, String)]
  {
    var pairs: [(String, String)] = []
    var removed: [String] = []
    var added: [String] = []
    func flush() {
      pairs.append(contentsOf: zip(removed, added).map { ($0, $1) })
      removed.removeAll()
      added.removeAll()
    }
    let table = lcsTable(before, after)
    var i = 0
    var j = 0
    while i < before.count || j < after.count {
      if i < before.count, j < after.count, before[i] == after[j] {
        flush()
        i += 1
        j += 1
      } else if j < after.count, i == before.count || table[i][j + 1] >= table[i + 1][j] {
        added.append(after[j])
        j += 1
      } else {
        removed.append(before[i])
        i += 1
      }
    }
    flush()
    return pairs
  }

  private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
    var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
    guard !a.isEmpty, !b.isEmpty else { return table }
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
      }
    }
    return table
  }
}
