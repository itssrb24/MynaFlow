import Foundation
import Testing

@testable import MynaFlowCore

private actor ScriptedModel: LocalLanguageModel {
  private(set) var instructions: [String] = []
  let reply: @Sendable (String) throws -> String

  init(reply: @escaping @Sendable (String) throws -> String) {
    self.reply = reply
  }

  func generateInstruction(_ instruction: String, maxTokens: Int) async throws -> String {
    instructions.append(instruction)
    return try reply(instruction)
  }
}

private let wellFormed = """
  KEY POINTS:
  - Launch moves to March
  * Budget approved
  ACTION ITEMS:
  - Sam drafts the announcement
  - None
  """

private func segments(_ count: Int, length: Int = 40) -> [MeetingSegment] {
  (0..<count).map {
    MeetingSegment(
      channel: $0.isMultiple(of: 2) ? .you : .others, startSeconds: Double($0 * 30),
      text: String(repeating: "w", count: length))
  }
}

@Suite("MeetingSummarizer")
struct MeetingSummarizerTests {
  @Test("no model installed → unavailable with the no-model note")
  func noModel() async {
    let outcome = await MeetingSummarizer(model: nil).summarize(segments(3))
    #expect(outcome == .unavailable(MeetingSummarizer.noModelNote))
  }

  @Test("an empty transcript is not sent to the model")
  func emptyTranscript() async {
    let model = ScriptedModel { _ in wellFormed }
    let outcome = await MeetingSummarizer(model: model).summarize([])
    guard case .unavailable = outcome else {
      Issue.record("expected unavailable, got \(outcome)")
      return
    }
    #expect(await model.instructions.isEmpty)
  }

  @Test("a short transcript is one call, parsed into key points and action items")
  func singlePass() async {
    let model = ScriptedModel { _ in wellFormed }
    let outcome = await MeetingSummarizer(model: model).summarize(segments(2))
    #expect(
      outcome
        == .summarized(
          MeetingSummary(
            keyPoints: ["Launch moves to March", "Budget approved"],
            actionItems: ["Sam drafts the announcement"])))
    #expect(await model.instructions.count == 1)
    #expect(await model.instructions[0].contains("You: "))
  }

  @Test("a long transcript maps each part, then reduces the notes once")
  func mapReduce() async {
    let model = ScriptedModel { _ in wellFormed }
    // 6 segments of ~60 rendered chars, 130-char parts → 3 map calls + 1 reduce.
    let summarizer = MeetingSummarizer(model: model, maxPartCharacters: 130)
    let outcome = await summarizer.summarize(segments(6))
    guard case .summarized = outcome else {
      Issue.record("expected summarized, got \(outcome)")
      return
    }
    let instructions = await model.instructions
    #expect(instructions.count == 4)
    #expect(instructions.last?.contains("Notes from part 3") == true)
  }

  @Test("a model failure is reported, not thrown")
  func modelFailure() async {
    let model = ScriptedModel { _ in throw LlamaServerError.emptyOutput }
    let outcome = await MeetingSummarizer(model: model).summarize(segments(2))
    guard case .failed = outcome else {
      Issue.record("expected failed, got \(outcome)")
      return
    }
  }

  @Test("unparseable output is a failure, not an empty summary")
  func unparseable() async {
    let model = ScriptedModel { _ in "Sure! Here you go." }
    let outcome = await MeetingSummarizer(model: model).summarize(segments(2))
    guard case .failed = outcome else {
      Issue.record("expected failed, got \(outcome)")
      return
    }
  }

  @Test("parse tolerates markdown headings and bullets")
  func parseVariants() {
    let summary = MeetingSummarizer.parse(
      """
      **Key points**
      • One
      ## Action items:
      1. Two
      """)
    #expect(summary == MeetingSummary(keyPoints: ["One"], actionItems: ["Two"]))
  }
}
