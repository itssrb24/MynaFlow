import Foundation
import Testing

@testable import MynaFlowCore

@Suite("CorrectionLearner — names learned from a hand-edited transcript line")
struct CorrectionLearnerTests {
  @Test("a proper-noun fix is learned")
  func properNoun() {
    let learned = CorrectionLearner.learn(
      original: "I asked Cucicello about timelines.", edited: "I asked Kokotajlo about timelines.")
    #expect(learned == [LearnedSubstitution(wrong: "Cucicello", right: "Kokotajlo")])
  }

  @Test("edits elsewhere in the line don't hide the substitution")
  func lengthChanges() {
    let learned = CorrectionLearner.learn(
      original: "so then Flewid Audio ran it", edited: "so then FluidAudio ran the job")
    #expect(learned.map(\.right) == ["FluidAudio"])
  }

  @Test("capitalization, punctuation, common words and short or lowercase words teach nothing")
  func ignored() {
    #expect(CorrectionLearner.learn(original: "we met priya today", edited: "we met Priya today").isEmpty)
    #expect(CorrectionLearner.learn(original: "There is more", edited: "Thera is more").isEmpty)
    #expect(CorrectionLearner.learn(original: "Thera is more", edited: "There is more").isEmpty)
    #expect(CorrectionLearner.learn(original: "the ab file", edited: "the cd file").isEmpty)
    #expect(CorrectionLearner.learn(original: "ship the widget", edited: "ship the gadget").isEmpty)
    #expect(CorrectionLearner.learn(original: "Priya agreed", edited: "Priya agreed.").isEmpty)
  }

  @Test("trailing punctuation doesn't stick to the learned words")
  func punctuationStripped() {
    let learned = CorrectionLearner.learn(original: "Thanks, Morris.", edited: "Thanks, Maurice.")
    #expect(learned == [LearnedSubstitution(wrong: "Morris", right: "Maurice")])
  }
}

@Suite("Editing a transcript turn")
struct TranscriptEditTests {
  let segments = [
    MeetingSegment(channel: .others, startSeconds: 0, text: "Hello there.", speaker: 1),
    MeetingSegment(channel: .you, startSeconds: 5, text: "Hi.", speaker: nil),
    MeetingSegment(channel: .others, startSeconds: 10, text: "First part.", speaker: 2),
    MeetingSegment(channel: .others, startSeconds: 30, text: "Second part.", speaker: 2),
  ]

  @Test("a turn made of several chunks becomes one segment with the new text")
  func replacesTurn() {
    let edited = MeetingTranscript.replacingTurn(
      startingAt: 10, channel: .others, with: "The whole turn.", in: segments)
    #expect(MeetingTranscript.turns(edited).map(\.text) == ["Hello there.", "Hi.", "The whole turn."])
    #expect(edited.last == MeetingSegment(channel: .others, startSeconds: 10, text: "The whole turn.", speaker: 2))
  }

  @Test("an unknown turn leaves the transcript alone")
  func unknown() {
    #expect(MeetingTranscript.replacingTurn(startingAt: 99, channel: .others, with: "x", in: segments) == segments)
  }
}

@Suite("Approved replacements in meeting text")
struct MeetingReplacementTests {
  @Test("only the approved word swaps apply — no filler removal or added periods")
  func onlyReplacements() {
    let rules = LearnedRules(
      approved: [LearnedRule(kind: .replacement, pattern: "morris", replacement: "Maurice", evidence: 2),
                 LearnedRule(kind: .filler, pattern: "basically", replacement: nil, evidence: 3)])
    let cleaner = TranscriptCleaner(learnedRules: rules)
    #expect(cleaner.replacingLearnedWords("um basically Morris said yes") == "um basically Maurice said yes")
  }

  @Test("with learning off nothing changes")
  func off() {
    let rules = LearnedRules(
      approved: [LearnedRule(kind: .replacement, pattern: "morris", replacement: "Maurice", evidence: 2)],
      enabled: false)
    #expect(TranscriptCleaner(learnedRules: rules).replacingLearnedWords("Morris said yes") == "Morris said yes")
  }
}

@Suite("Notes and flags in the summary")
struct MeetingNotesSummaryTests {
  let segments = (0..<10).map {
    MeetingSegment(channel: .others, startSeconds: Double($0) * 30, text: "Line \($0).", speaker: nil)
  }

  @Test("a flag covers the 40 seconds before it")
  func flagWindow() {
    let flag = MeetingNote(kind: .flag, seconds: 100)
    #expect(flag.covers(60) && flag.covers(100) && !flag.covers(59) && !flag.covers(101))
  }

  @Test("the summary context carries notes and the flagged lines")
  func context() {
    let record = MeetingRecord(
      startedAt: Date(), durationSeconds: 300, segments: segments, summary: nil, summaryNote: nil,
      notes: [MeetingNote(kind: .note, seconds: 65, text: "Ask about budget"),
              MeetingNote(kind: .flag, seconds: 95)])
    let context = record.summaryContext()
    #expect(context.notes == ["[01:05] Ask about budget"])
    #expect(context.flagged == ["[01:35] Line 2. Line 3."])
    let header = MeetingSummarizer.contextHeader(context)
    #expect(header.contains("Ask about budget"))
    #expect(header.contains("flagged"))
  }

  @Test("a note can't fake a summary heading")
  func sanitized() {
    let context = SummaryContext(notes: ["ACTION ITEMS: none"])
    #expect(!MeetingSummarizer.contextHeader(context).contains("ACTION ITEMS:"))
  }

  @Test("notes change the summary basis")
  func basis() {
    let plain = MeetingRecord(startedAt: Date(), durationSeconds: 1, segments: [], summary: nil, summaryNote: nil)
    let noted = MeetingRecord(
      startedAt: plain.startedAt, durationSeconds: 1, segments: [], summary: nil, summaryNote: nil,
      notes: [MeetingNote(kind: .note, seconds: 1, text: "Hi")])
    #expect(plain.currentSummaryBasis != noted.currentSummaryBasis)
  }
}

private func storeURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("learning-tests-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("flow.sqlite", isDirectory: false)
}

@Suite("Meeting edits and notes in the store")
struct MeetingLearningStoreTests {
  func meeting() -> MeetingRecord {
    MeetingRecord(
      startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 60,
      segments: [MeetingSegment(channel: .others, startSeconds: 0, text: "Thanks Morris.", speaker: 1)],
      summary: nil, summaryNote: nil,
      notes: [MeetingNote(kind: .note, seconds: 12, text: "Budget"), MeetingNote(kind: .flag, seconds: 40)])
  }

  @Test("notes and flags survive saving")
  func notesPersist() async throws {
    let store = try await FlowStore.open(at: storeURL())
    let record = meeting()
    try await store.insertMeeting(record)
    #expect(try await store.meeting(id: record.id)?.notes == record.notes)
    await store.close()
  }

  @Test("editing a turn saves the text, learns the name, and suggests the fix — repeats add evidence")
  func editLearns() async throws {
    let store = try await FlowStore.open(at: storeURL())
    let record = meeting()
    try await store.insertMeeting(record)

    let learned = try await store.editTurn(
      startingAt: 0, channel: .others, text: "Thanks Maurice.", meetingID: record.id)
    #expect(learned == [LearnedSubstitution(wrong: "Morris", right: "Maurice")])
    #expect(try await store.meeting(id: record.id)?.segments.map(\.text) == ["Thanks Maurice."])
    #expect(try await store.vocabularyTerms().map(\.term).contains("Maurice"))
    let suggested = try await store.learnedRules(status: .suggested).map(\.rule)
    #expect(suggested == [LearnedRule(kind: .replacement, pattern: "morris", replacement: "Maurice", evidence: 1)])

    let second = meeting()
    try await store.insertMeeting(second)
    _ = try await store.editTurn(startingAt: 0, channel: .others, text: "Thanks Maurice.", meetingID: second.id)
    #expect(try await store.learnedRules(status: .suggested).first?.rule.evidence == 2)
    await store.close()
  }
}
