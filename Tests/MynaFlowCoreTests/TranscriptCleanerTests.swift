import Foundation
import Testing

@testable import MynaFlowCore

@Suite("TranscriptCleaner")
struct TranscriptCleanerTests {
  private let cleaner = TranscriptCleaner()

  @Test(
    "Fixture table: raw transcript → cleaned text",
    arguments: [
      // Filler words
      ("Um, so this is a test.", "So this is a test."),
      ("Uh, I think we should go.", "I think we should go."),
      ("This is, um, exactly what I meant.", "This is exactly what I meant."),
      ("Er, right.", "Right."),
      ("Hmm, let me think about that.", "Let me think about that."),
      // "you know" only removed when parenthetical (comma-wrapped)
      ("It was, you know, kind of hard.", "It was kind of hard."),
      ("You know the answer already.", "You know the answer already."),
      // "like" only removed in parenthetical comma pattern
      ("It was, like, really far away.", "It was really far away."),
      ("I like this design.", "I like this design."),
      ("It looks like rain.", "It looks like rain."),
      // Stutters and immediate repetition
      ("The the meeting starts at noon.", "The meeting starts at noon."),
      ("I I think it works.", "I think it works."),
      ("I I I think it works.", "I think it works."),
      ("We can we can try again tomorrow.", "We can try again tomorrow."),
      // Intentional doubles survive
      ("He had had enough of it.", "He had had enough of it."),
      ("It is very very important.", "It is very very important."),
      ("They arrived that that afternoon brought rain.", "They arrived that afternoon brought rain."),
      // No collapse across sentence boundaries
      ("That is true. True words matter.", "That is true. True words matter."),
      // Combined
      ("Um, so this is is a test.", "So this is a test."),
      (
        "Uh, the the report is, you know, basically done.",
        "The report is basically done."
      ),
      // Seam repair: capitalization after leading removal, terminal punctuation
      ("um hello there", "Hello there."),
      ("The result was fine", "The result was fine."),
      // False starts: short abandoned fragment before an em dash is dropped
      ("I was going to — actually let me check.", "Actually let me check."),
      // Long pre-dash clauses are real content, not false starts
      (
        "The design we shipped last quarter — it works.",
        "The design we shipped last quarter — it works."
      ),
      // Whitespace normalization
      ("  So   many    spaces.  ", "So many spaces."),
      // Empty and filler-only input
      ("", ""),
      ("Um, uh.", ""),
      // Case-insensitive repetition collapse keeps the first token's casing
      ("The The meeting is on.", "The meeting is on."),
    ])
  func fixtures(raw: String, expected: String) {
    #expect(cleaner.clean(raw).text == expected)
  }

  @Test("Cleaning is idempotent over the fixture set")
  func idempotent() {
    let samples = [
      "Um, so this is is a test.",
      "Uh, the the report is, you know, basically done.",
      "He had had enough of it.",
      "um hello there",
    ]
    for sample in samples {
      let once = cleaner.clean(sample).text
      let twice = cleaner.clean(once).text
      #expect(twice == once, "not idempotent for: \(sample)")
    }
  }

  @Test("Vocabulary terms are never treated as filler")
  func vocabularyProtected() {
    // A user whose vocabulary contains a term that matches a filler word —
    // e.g. dictating about the interjection itself — keeps it.
    let protective = TranscriptCleaner(protectedTerms: ["Umm Kulthum"])
    let cleaned = protective.clean("We listened to Umm Kulthum records.")
    #expect(cleaned.text == "We listened to Umm Kulthum records.")
  }

  @Test("User-added filler words are removed like the built-in list")
  func userFillers() {
    let custom = TranscriptCleaner(userFillers: ["basically", "right"])
    #expect(custom.clean("Basically we ship it, right.").text == "We ship it.")
    // The default list is unaffected.
    #expect(cleaner.clean("Basically we ship it.").text == "Basically we ship it.")
  }

  @Test("Terminal punctuation can be left off for chat-style targets")
  func noTerminalPunctuation() {
    #expect(cleaner.clean("um send it now", terminalPunctuation: false).text == "Send it now")
    // Punctuation the speaker supplied is kept either way.
    #expect(cleaner.clean("Really?", terminalPunctuation: false).text == "Really?")
  }

  @Test("Removals report the dropped spans")
  func removalsReported() {
    let result = cleaner.clean("Um, so this is is a test.")
    #expect(!result.removals.isEmpty)
  }

  @Test("Disabled cleaner returns input with only whitespace normalization")
  func disabledPassthrough() {
    let raw = "Um, the the report."
    let result = cleaner.clean(raw, enabled: false)
    #expect(result.text == raw)
    #expect(result.removals.isEmpty)
  }

  @Test("30s-of-speech-sized transcript cleans within budget")
  func performance() {
    // ~90 words ≈ 30 s of speech; run 100x and require well under the 300 ms
    // budget for a single pass.
    let sentence = "Um, so the the quarterly report is, you know, basically ready for review and I I think we should send it out tomorrow morning. "
    let transcript = String(repeating: sentence, count: 5)
    let start = ContinuousClock.now
    for _ in 0..<100 {
      _ = cleaner.clean(transcript)
    }
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .milliseconds(3000), "100 passes took \(elapsed); budget is 300 ms per pass")
  }
}
