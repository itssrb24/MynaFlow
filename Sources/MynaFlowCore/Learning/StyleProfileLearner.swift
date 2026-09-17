import Foundation

/// Turns the user's post-insertion edits into rule suggestions. Pure and
/// conservative: every suggestion needs repeated, identical evidence, and
/// nothing here changes behavior — only approval does.
public enum StyleProfileLearner {
  static let replacementThreshold = 2
  static let fillerThreshold = 3
  static let formattingThreshold = 3

  public static func suggest(
    corrections: [CorrectionPair],
    records: [DictationRecord],
    existing: [LearnedRule] = []
  ) -> [LearnedRule] {
    var replacementCounts: [String: (replacement: String, count: Int)] = [:]
    var fillerCounts: [String: Int] = [:]
    var trailingPeriodRemovals = 0

    for pair in corrections {
      let before = words(pair.before)
      let after = words(pair.after)

      // Whole-phrase replacement: "gonna" → "going to".
      if before.count == 1, !after.isEmpty, before != after {
        let key = before[0].lowercased()
        let current = replacementCounts[key]
        if current == nil || current?.replacement == pair.after.trimmingCharacters(in: .whitespaces) {
          replacementCounts[key] = (pair.after.trimmingCharacters(in: .whitespaces), (current?.count ?? 0) + 1)
        }
      }

      // Single deleted word with everything else intact: a personal filler.
      if before.count == after.count + 1 {
        for index in before.indices {
          var trial = before
          let removed = trial.remove(at: index)
          if trial.map({ $0.lowercased() }) == after.map({ $0.lowercased() }) {
            fillerCounts[removed.lowercased(), default: 0] += 1
            break
          }
        }
      }

      // Trailing period removed and nothing else changed.
      let trimmedBefore = pair.before.trimmingCharacters(in: .whitespaces)
      let trimmedAfter = pair.after.trimmingCharacters(in: .whitespaces)
      if trimmedBefore.hasSuffix("."), String(trimmedBefore.dropLast()) == trimmedAfter {
        trailingPeriodRemovals += 1
      }
    }

    let known = Set(existing.map { "\($0.kind.rawValue):\($0.pattern.lowercased())" })
    var suggestions: [LearnedRule] = []

    for (word, entry) in replacementCounts.sorted(by: { $0.key < $1.key })
    where entry.count >= replacementThreshold && !known.contains("replacement:\(word)") {
      suggestions.append(
        LearnedRule(kind: .replacement, pattern: word, replacement: entry.replacement, evidence: entry.count))
    }
    for (word, count) in fillerCounts.sorted(by: { $0.key < $1.key })
    where count >= fillerThreshold && !known.contains("filler:\(word)") {
      suggestions.append(LearnedRule(kind: .filler, pattern: word, replacement: nil, evidence: count))
    }
    if trailingPeriodRemovals >= formattingThreshold,
      !known.contains("formatting:\(LearnedRule.noTerminalPeriod)")
    {
      suggestions.append(
        LearnedRule(
          kind: .formatting, pattern: LearnedRule.noTerminalPeriod, replacement: nil,
          evidence: trailingPeriodRemovals))
    }
    return suggestions
  }

  private static func words(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map {
      String($0).trimmingCharacters(in: .punctuationCharacters)
    }.filter { !$0.isEmpty }
  }
}
