import Foundation

/// One piece of text the cleaner dropped, kept for a future "show what was
/// cleaned" UI and for correction learning.
public struct CleanupRemoval: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case filler
    case repetition
    case falseStart
  }

  public let kind: Kind
  public let text: String
}

public struct CleanupResult: Equatable, Sendable {
  public let text: String
  public let removals: [CleanupRemoval]
}

/// Rule-based disfluency remover + seam repairer. The engines already emit
/// punctuated, capitalized text, so this never invents punctuation beyond
/// repairing the seams its own removals create. Deliberately conservative:
/// a missed filler is annoying, a removed real word changes meaning.
public struct TranscriptCleaner: Sendable {
  /// Words never treated as disfluencies, derived from user vocabulary.
  private let protectedWords: Set<String>

  private static let singleFillers: Set<String> = [
    "um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mmm",
  ]
  /// Removed only when comma-wrapped ("It was, like, hard") — as plain words
  /// they are ordinary English.
  private static let parentheticalFillers: [[String]] = [["you", "know"], ["like"]]
  /// Legitimate immediate doubles that must never collapse.
  private static let repetitionGuard: Set<String> = ["had", "very", "really"]
  private static let maxFalseStartWords = 4

  public init(protectedTerms: [String] = []) {
    var words: Set<String> = []
    for term in protectedTerms {
      for word in term.split(separator: " ") {
        words.insert(word.lowercased())
      }
    }
    protectedWords = words
  }

  public func clean(_ raw: String, enabled: Bool = true) -> CleanupResult {
    guard enabled else { return CleanupResult(text: raw, removals: []) }

    var tokens = Self.tokenize(raw)
    var removals: [CleanupRemoval] = []
    removeFillers(&tokens, removals: &removals)
    removeFalseStarts(&tokens, removals: &removals)
    collapseRepetitions(&tokens, removals: &removals)
    repairSeams(&tokens)
    return CleanupResult(text: Self.render(tokens), removals: removals)
  }

  // MARK: - Tokens

  private struct Token {
    var prefix: String
    var core: String
    var suffix: String
    var needsCapital = false

    var endsSentence: Bool {
      suffix.contains(where: { ".!?".contains($0) })
    }

    var endsWithComma: Bool { suffix.hasSuffix(",") }

    var text: String { prefix + core + suffix }
  }

  private static func tokenize(_ raw: String) -> [Token] {
    raw.split(whereSeparator: \.isWhitespace).map { chunk in
      let scalars = Array(chunk)
      var start = 0
      var end = scalars.count
      while start < end, !scalars[start].isLetter, !scalars[start].isNumber { start += 1 }
      while end > start, !scalars[end - 1].isLetter, !scalars[end - 1].isNumber { end -= 1 }
      return Token(
        prefix: String(scalars[0..<start]),
        core: String(scalars[start..<end]),
        suffix: String(scalars[end...]))
    }
  }

  private static func render(_ tokens: [Token]) -> String {
    tokens.map(\.text).joined(separator: " ")
  }

  private func isSentenceStart(_ tokens: [Token], _ index: Int) -> Bool {
    index == 0 || tokens[index - 1].endsSentence
  }

  private func isProtected(_ token: Token) -> Bool {
    protectedWords.contains(token.core.lowercased())
  }

  // MARK: - Passes

  private func removeFillers(_ tokens: inout [Token], removals: inout [CleanupRemoval]) {
    var index = 0
    while index < tokens.count {
      if let length = fillerLength(tokens, at: index) {
        removeRange(&tokens, index..<(index + length), kind: .filler, removals: &removals)
        // Re-examine the same index: fillers can be adjacent ("Um, uh.").
        continue
      }
      index += 1
    }
  }

  /// Number of tokens the filler occupies at `index`, or nil when none.
  private func fillerLength(_ tokens: [Token], at index: Int) -> Int? {
    let token = tokens[index]
    guard !isProtected(token) else { return nil }
    let core = token.core.lowercased()

    if Self.singleFillers.contains(core) {
      return 1
    }

    for phrase in Self.parentheticalFillers {
      guard index + phrase.count <= tokens.count else { continue }
      let candidate = tokens[index..<(index + phrase.count)]
      guard candidate.map({ $0.core.lowercased() }) == phrase,
        !candidate.contains(where: isProtected)
      else { continue }
      // Parenthetical only: comma before and comma after.
      let last = tokens[index + phrase.count - 1]
      guard index > 0, tokens[index - 1].endsWithComma, last.endsWithComma else { continue }
      return phrase.count
    }
    return nil
  }

  private func removeFalseStarts(_ tokens: inout [Token], removals: inout [CleanupRemoval]) {
    var index = 0
    while index < tokens.count {
      // A restart cue is an em dash between words; treat the words from the
      // sentence start up to the dash as abandoned when the fragment is short.
      let hasDash = tokens[index].suffix.contains("—") || tokens[index].suffix.contains("--")
      let dashOnly = tokens[index].core.isEmpty && tokens[index].prefix.contains("—")
      guard hasDash || dashOnly else {
        index += 1
        continue
      }
      var start = index
      while start > 0, !tokens[start - 1].endsSentence { start -= 1 }
      let fragmentWordCount = tokens[start...index].filter { !$0.core.isEmpty }.count
      let hasContinuation = index + 1 < tokens.count
      if hasContinuation, fragmentWordCount <= Self.maxFalseStartWords {
        removeRange(&tokens, start..<(index + 1), kind: .falseStart, removals: &removals)
        index = start
      } else {
        index += 1
      }
    }
  }

  private func collapseRepetitions(_ tokens: inout [Token], removals: inout [CleanupRemoval]) {
    var index = 0
    while index < tokens.count {
      // Bigram: "we can we can" — drop the second pair.
      if index + 3 < tokens.count,
        !tokens[index].endsSentence, !tokens[index + 1].endsSentence,
        !tokens[index + 2].endsSentence,
        !tokens[index].core.isEmpty, !tokens[index + 1].core.isEmpty,
        tokens[index].core.lowercased() == tokens[index + 2].core.lowercased(),
        tokens[index + 1].core.lowercased() == tokens[index + 3].core.lowercased()
      {
        removeRange(&tokens, (index + 2)..<(index + 4), kind: .repetition, removals: &removals)
        continue
      }
      // Unigram: "the the" — drop the second, keep the first token's casing.
      if index + 1 < tokens.count,
        !tokens[index].endsSentence,
        !tokens[index].core.isEmpty,
        tokens[index].core.lowercased() == tokens[index + 1].core.lowercased(),
        !Self.repetitionGuard.contains(tokens[index].core.lowercased()),
        !isProtected(tokens[index])
      {
        removeRange(&tokens, (index + 1)..<(index + 2), kind: .repetition, removals: &removals)
        continue
      }
      index += 1
    }
  }

  /// Splice out a token range, merging the punctuation seams it leaves behind.
  private func removeRange(
    _ tokens: inout [Token], _ range: Range<Int>, kind: CleanupRemoval.Kind,
    removals: inout [CleanupRemoval]
  ) {
    let removedText = tokens[range].map(\.text).joined(separator: " ")
    removals.append(CleanupRemoval(kind: kind, text: removedText))

    let atSentenceStart = isSentenceStart(tokens, range.lowerBound)
    let removedLast = tokens[range.upperBound - 1]

    if range.lowerBound > 0, !atSentenceStart {
      // "This is, um, exactly" — the comma before the removal is now stray.
      if tokens[range.lowerBound - 1].endsWithComma, removedLast.endsWithComma {
        tokens[range.lowerBound - 1].suffix.removeLast()
      }
      // "I paused, um." — carry sentence-ending punctuation back.
      if removedLast.endsSentence {
        if tokens[range.lowerBound - 1].endsWithComma {
          tokens[range.lowerBound - 1].suffix.removeLast()
        }
        tokens[range.lowerBound - 1].suffix += removedLast.suffix.filter { ".!?".contains($0) }
      }
    }

    tokens.removeSubrange(range)

    if atSentenceStart, range.lowerBound < tokens.count {
      tokens[range.lowerBound].needsCapital = true
    }
  }

  private func repairSeams(_ tokens: inout [Token]) {
    for index in tokens.indices where tokens[index].needsCapital {
      let core = tokens[index].core
      guard let first = core.first, first.isLowercase else { continue }
      tokens[index].core = first.uppercased() + core.dropFirst()
    }
    // Ensure terminal punctuation on non-empty output.
    if let last = tokens.indices.last, !tokens[last].endsSentence, !tokens[last].core.isEmpty {
      tokens[last].suffix += "."
    }
  }
}
