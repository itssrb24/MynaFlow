import Foundation
import Testing

@testable import MynaFlowCore

@Suite("SpeakerAlignment — splitting an Others chunk by who spoke")
struct SpeakerAlignmentTests {
  func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
    TimedWord(text: text, start: start, end: end)
  }

  func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn {
    SpeakerTurn(speaker: speaker, start: start, end: end)
  }

  @Test("a chunk with one speaker keeps the engine's full text, labelled")
  func oneSpeaker() {
    let pieces = SpeakerAlignment.pieces(
      text: "Hello everyone, let's start.",
      words: [word("Hello", 0, 0.5), word("everyone,", 0.5, 1.2), word("let's", 1.4, 1.7),
              word("start.", 1.7, 2.2)],
      duration: 30, turns: [turn("A", 0, 2.5)])
    #expect(pieces == [SpeakerPiece(text: "Hello everyone, let's start.", start: 0, speaker: "A")])
  }

  @Test("words are cut where the speaker changes")
  func splitAtChange() {
    let words = [
      word("Any", 0, 0.4), word("updates", 0.4, 1.0), word("today?", 1.0, 1.6),
      word("Yes,", 2.0, 2.4), word("the", 2.4, 2.6), word("launch", 2.6, 3.1),
      word("moved.", 3.1, 3.7),
    ]
    let pieces = SpeakerAlignment.pieces(
      text: "Any updates today? Yes, the launch moved.", words: words, duration: 30,
      turns: [turn("A", 0, 1.8), turn("B", 1.9, 4.0)])
    #expect(
      pieces == [
        SpeakerPiece(text: "Any updates today?", start: 0, speaker: "A"),
        SpeakerPiece(text: "Yes, the launch moved.", start: 2.0, speaker: "B"),
      ])
  }

  @Test("a stray word under a second long joins its neighbour instead of becoming a line")
  func shortPieceMerges() {
    let words = [
      word("We", 0, 0.3), word("should", 0.3, 0.7), word("ship", 0.7, 1.1), word("it", 1.1, 1.3),
      word("now", 1.3, 1.6), word("okay", 1.6, 1.9),
    ]
    // "okay" alone falls in B's turn but is only 0.3 s.
    let pieces = SpeakerAlignment.pieces(
      text: "We should ship it now okay", words: words, duration: 30,
      turns: [turn("A", 0, 1.55), turn("B", 1.55, 2.0)])
    #expect(pieces == [SpeakerPiece(text: "We should ship it now okay", start: 0, speaker: "A")])
  }

  @Test("short exchanges split even when the engine's word timings are near-instant")
  func emissionTimings() {
    // Parakeet reports when each token was emitted, not how long it lasted:
    // words are ~0.08 s "long" though the sentence takes over a second.
    let words = [
      word("Sounds", 0.0, 0.08), word("good", 0.4, 0.48), word("to", 0.7, 0.78), word("me.", 1.1, 1.18),
      word("The", 1.6, 1.68), word("beta", 1.9, 1.98), word("date", 2.3, 2.38), word("works.", 2.8, 2.88),
    ]
    let pieces = SpeakerAlignment.pieces(
      text: "Sounds good to me. The beta date works.", words: words, duration: 30,
      turns: [turn("A", 0, 1.4), turn("B", 1.5, 3.0)])
    #expect(pieces.map(\.speaker) == ["A", "B"])
  }

  @Test("words between turns keep the speaker before them")
  func gapsInherit() {
    let words = [
      word("First", 0, 0.6), word("point", 0.6, 1.2), word("is", 5.0, 5.2), word("budget.", 5.2, 5.9),
    ]
    let pieces = SpeakerAlignment.pieces(
      text: "First point is budget.", words: words, duration: 30, turns: [turn("A", 0, 1.5)])
    #expect(pieces == [SpeakerPiece(text: "First point is budget.", start: 0, speaker: "A")])
  }

  @Test("without word timings the whole chunk goes to the speaker heard most")
  func noWordsMostOverlap() {
    let pieces = SpeakerAlignment.pieces(
      text: "Mostly B talking here.", words: nil, duration: 30,
      turns: [turn("A", 0, 4), turn("B", 4, 25)])
    #expect(pieces == [SpeakerPiece(text: "Mostly B talking here.", start: 0, speaker: "B")])
  }

  @Test("with no speaker turns at all, the text stays unlabelled")
  func noTurns() {
    let pieces = SpeakerAlignment.pieces(
      text: "Hello.", words: [word("Hello.", 0, 0.5)], duration: 30, turns: [])
    #expect(pieces == [SpeakerPiece(text: "Hello.", start: 0, speaker: nil)])
  }

  @Test("overlapping turns resolve the same way every time: earliest start wins")
  func overlapDeterministic() {
    let words = [word("Both", 1.0, 1.4), word("talking", 1.4, 2.0)]
    let a = SpeakerAlignment.pieces(
      text: "Both talking", words: words, duration: 30, turns: [turn("B", 0.5, 3), turn("A", 0, 3)])
    let b = SpeakerAlignment.pieces(
      text: "Both talking", words: words, duration: 30, turns: [turn("A", 0, 3), turn("B", 0.5, 3)])
    #expect(a == b)
    #expect(a.first?.speaker == "A")
  }
}

@Suite("SpeakerNumbering — Speaker 1, 2, … in order of first appearance")
struct SpeakerNumberingTests {
  @Test("numbers follow first appearance and stay put")
  func stable() {
    var numbering = SpeakerNumbering()
    #expect(numbering.number(for: "spk_7") == 1)
    #expect(numbering.number(for: "spk_2") == 2)
    #expect(numbering.number(for: "spk_7") == 1)
    #expect(numbering.number(for: "spk_9") == 3)
  }
}
