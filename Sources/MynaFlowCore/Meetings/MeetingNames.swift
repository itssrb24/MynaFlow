import Foundation

/// Conservative fixer for near-miss names (ported from the Myna app):
/// "Kokotailo" → "Kokotajlo" when Kokotajlo is on the invite. Narrow on
/// purpose — a wrong "correction" is worse than a mishear — so only tiny,
/// unambiguous edits are made; far misses are left for the hints to prevent.
public enum NameCorrector {
  /// Capitalized words that are common speech, never candidates.
  static let commonWords: Set<String> = [
    "the", "this", "that", "these", "those", "there", "then", "they", "them", "their",
    "when", "where", "what", "which", "while", "who", "whom", "whose", "why", "how",
    "well", "okay", "yeah", "yes", "right", "sure", "now", "just", "like", "look",
    "listen", "also", "and", "but", "so", "because", "maybe", "actually", "anyway",
    "alright", "thanks", "thank", "hello", "great", "good", "people", "please",
    "today", "tomorrow", "yesterday",
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "january", "february", "march", "april", "may", "june", "july", "august",
    "september", "october", "november", "december",
  ]

  /// `learned` maps a lowercased mishearing the user corrected by hand to its
  /// fix; it applies whatever the distance — a person confirmed that pair.
  public static func correct(
    _ text: String, knownNames: [String], learned: [String: String] = [:]
  ) -> String {
    let targets = knownNames.flatMap { $0.split(separator: " ") }.map(String.init)
      .filter { $0.count >= 4 }
    guard !targets.isEmpty || !learned.isEmpty else { return text }
    return text.split(separator: " ", omittingEmptySubsequences: false)
      .map { correctToken(String($0), targets: targets, learned: learned) }
      .joined(separator: " ")
  }

  private static func correctToken(_ token: String, targets: [String], learned: [String: String])
    -> String
  {
    let core = token.trimmingCharacters(in: .punctuationCharacters)
    if let replacement = learned[core.lowercased()] {
      return token.replacingOccurrences(of: core, with: replacement)
    }
    guard core.count >= 4, core.first?.isUppercase == true, core.allSatisfy(\.isLetter),
      !commonWords.contains(core.lowercased()), !targets.isEmpty,
      !targets.contains(where: { $0.caseInsensitiveCompare(core) == .orderedSame })
    else { return token }
    let scored = targets.map { (name: $0, distance: levenshtein(core.lowercased(), $0.lowercased())) }
      .sorted { $0.distance < $1.distance }
    guard let best = scored.first, plausible(core, best) else { return token }
    if scored.count > 1, scored[1].distance <= best.distance + 1,
      scored[1].name.caseInsensitiveCompare(best.name) != .orderedSame
    {
      return token  // two names nearly as close: refuse to guess
    }
    return token.replacingOccurrences(of: core, with: best.name)
  }

  /// Distance 1, or 2 when the consonant skeletons agree; plus a shared
  /// first sound class and a normalized-distance cap.
  private static func plausible(_ core: String, _ candidate: (name: String, distance: Int)) -> Bool {
    let ratio = Double(candidate.distance) / Double(max(core.count, candidate.name.count))
    guard ratio <= 0.34,
      soundClass(core.lowercased().first) == soundClass(candidate.name.lowercased().first)
    else { return false }
    return candidate.distance <= 1 || (candidate.distance == 2 && skeleton(core) == skeleton(candidate.name))
  }

  private static func skeleton(_ word: String) -> [Int] {
    var out: [Int] = []
    for char in word.lowercased() {
      guard let cls = soundClass(char), cls != 0 else { continue }
      if out.last != cls { out.append(cls) }
    }
    return out
  }

  private static func soundClass(_ char: Character?) -> Int? {
    guard let char else { return nil }
    switch char {
    case "b", "p", "f", "v": return 1
    case "c", "g", "j", "k", "q", "s", "x", "z": return 2
    case "d", "t": return 3
    case "l": return 4
    case "m", "n": return 5
    case "r": return 6
    default: return 0
    }
  }

  static func levenshtein(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
      }
      swap(&previous, &current)
    }
    return previous[b.count]
  }
}

/// The words a meeting's speech engine is told to listen for: the people on
/// the invite first (names are what engines get wrong), then the user's own
/// vocabulary, then names that appear in the invite's title and agenda.
public enum MeetingHints {
  public static func terms(context: MeetingContext?, vocabulary: [String]) -> [String] {
    let people = context?.others.map(\.displayName) ?? []
    let invite = [context?.title, context?.agenda].compactMap { $0 }.flatMap(properNouns)
    return BiasTerms.sanitize(people + vocabulary + invite)
  }

  /// Capitalized words that aren't just starting a sentence or list item.
  static func properNouns(in text: String) -> [String] {
    var nouns: [String] = []
    for line in text.components(separatedBy: .newlines) {
      var sentenceStart = true
      for raw in line.split(whereSeparator: \.isWhitespace) {
        let token = String(raw)
        let word = token.trimmingCharacters(in: .punctuationCharacters)
        defer {
          let isListMarker = word.allSatisfy(\.isNumber) && !word.isEmpty
          sentenceStart = isListMarker || token.last.map { ".!?:".contains($0) } ?? false
        }
        guard !sentenceStart, word.count >= 3, word.first?.isUppercase == true,
          word.allSatisfy(\.isLetter), !NameCorrector.commonWords.contains(word.lowercased())
        else { continue }
        nouns.append(word)
      }
    }
    return nouns
  }
}

/// Engines invent words in near-silence ("Thank you." over a quiet
/// stretch). Real speech runs well under a second per word; the Myna app
/// measured hallucinations at seven seconds a word and more.
public enum SpeechSanity {
  public static func isHallucination(words: [TimedWord]?) -> Bool {
    guard let words, words.count >= 1, let first = words.first, let last = words.last else {
      return false
    }
    let span = last.end - first.start
    return span >= 5 && span / Double(words.count) > 3
  }
}
