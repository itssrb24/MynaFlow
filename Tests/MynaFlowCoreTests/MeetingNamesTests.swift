import Foundation
import Testing

@testable import MynaFlowCore

/// Ported from the Myna app's NameCorrectorTests: a wrong "correction" is
/// worse than a mishear, so only tiny, unambiguous near-misses are fixed.
@Suite("NameCorrector — fixing near-miss names from the invite")
struct NameCorrectorTests {
  let known = ["Daniel Kokotajlo", "Priya Sharma", "Diego Ramírez"]

  @Test("a near-miss surname is fixed")
  func nearMissSurname() {
    #expect(
      NameCorrector.correct("I asked Kokotailo about timelines.", knownNames: known)
        == "I asked Kokotajlo about timelines.")
  }

  @Test("a near-miss first name is fixed, keeping punctuation")
  func nearMissFirstName() {
    #expect(NameCorrector.correct("Thanks, Preya!", knownNames: known) == "Thanks, Priya!")
  }

  @Test("correct names are left alone")
  func correctNamesAlone() {
    let text = "Priya Sharma and Diego Ramírez agreed."
    #expect(NameCorrector.correct(text, knownNames: known) == text)
  }

  @Test("common capitalized words are never touched")
  func commonWords() {
    let text = "Well, that said, There is more. Sharing is fine."
    #expect(NameCorrector.correct(text, knownNames: ["Shari Ng", "Thera Vance"]) == text)
  }

  @Test("lowercase and short words are untouched")
  func lowercaseAndShort() {
    let text = "the kokotailo protocol ran on Pia's laptop"
    #expect(NameCorrector.correct(text, knownNames: known) == text)
  }

  @Test("two known names nearly as close: refuse to guess")
  func ambiguity() {
    let text = "Ask Prisha about it."
    #expect(NameCorrector.correct(text, knownNames: ["Priya Kapoor", "Prish Kapoor"]) == text)
  }

  @Test("far misses are left for the hints to prevent")
  func farMiss() {
    let text = "We heard Cucicello speak."
    #expect(NameCorrector.correct(text, knownNames: known) == text)
  }

  @Test("a correction the user taught applies whatever the distance")
  func learnedOverride() {
    #expect(
      NameCorrector.correct("Ask Cucicello.", knownNames: [], learned: ["cucicello": "Cuccinello"])
        == "Ask Cuccinello.")
  }
}

@Suite("MeetingHints — what the speech engine is told to listen for")
struct MeetingHintsTests {
  @Test("attendees come first, then vocabulary, then names from the invite")
  func priority() {
    let context = MeetingContext(
      title: "Launch sync with Crunchyroll",
      attendees: [
        MeetingAttendee(name: "Me Myself", email: "me@x.com", isSelf: true),
        MeetingAttendee(name: "Maurice Lee", email: "maurice@x.com"),
      ],
      agenda: "Review the Airtable plan with Ty.")
    let hints = MeetingHints.terms(context: context, vocabulary: ["Parakeet", "Gemma"])
    #expect(Array(hints.prefix(3)) == ["Maurice Lee", "Parakeet", "Gemma"])
    #expect(hints.contains("Crunchyroll"))
    #expect(hints.contains("Airtable"))
    #expect(!hints.contains("Me Myself"))
    #expect(!hints.contains("Launch"))  // sentence-start capital, not a name
  }

  @Test("without an invite, the vocabulary is still used")
  func noContext() {
    #expect(MeetingHints.terms(context: nil, vocabulary: ["Gemma"]) == ["Gemma"])
  }

  @Test("the list is capped")
  func capped() {
    let vocabulary = (1...300).map { "Term\($0)" }
    #expect(MeetingHints.terms(context: nil, vocabulary: vocabulary).count <= 100)
  }
}

@Suite("SpeechSanity — engines invent words in near-silence")
struct SpeechSanityTests {
  func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
  }

  @Test("two words spread over twenty seconds is a hallucination")
  func sparse() {
    #expect(SpeechSanity.isHallucination(words: [word("Thank", 2, 3), word("you.", 21, 22)]))
  }

  @Test("normal speech is kept, and so is anything without timings")
  func normal() {
    let words = (0..<20).map { word("w\($0)", Double($0) * 0.4, Double($0) * 0.4 + 0.3) }
    #expect(!SpeechSanity.isHallucination(words: words))
    #expect(!SpeechSanity.isHallucination(words: nil))
    #expect(!SpeechSanity.isHallucination(words: [word("Yes.", 0, 0.4)]))
  }
}
