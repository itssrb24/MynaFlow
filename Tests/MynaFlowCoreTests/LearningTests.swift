import Foundation
import Testing

@testable import MynaFlowCore

@Suite("StyleProfileLearner")
struct StyleProfileLearnerTests {
  private func correction(_ before: String, _ after: String) -> CorrectionPair {
    CorrectionPair(before: before, after: after)
  }

  @Test("A replacement seen twice becomes a suggested replacement rule")
  func replacementRule() {
    let corrections = [
      correction("gonna", "going to"),
      correction("gonna", "going to"),
      correction("wanna", "want to"),  // only once — not enough evidence
    ]
    let suggestions = StyleProfileLearner.suggest(corrections: corrections, records: [])
    #expect(
      suggestions == [
        LearnedRule(kind: .replacement, pattern: "gonna", replacement: "going to", evidence: 2)
      ])
  }

  @Test("Words the user repeatedly deletes become suggested fillers")
  func fillerRule() {
    let corrections = [
      correction("basically the plan", "the plan"),
      correction("basically we ship", "we ship"),
      correction("it is basically done", "it is done"),
    ]
    let suggestions = StyleProfileLearner.suggest(corrections: corrections, records: [])
    #expect(suggestions.contains(LearnedRule(kind: .filler, pattern: "basically", replacement: nil, evidence: 3)))
  }

  @Test("Removing the terminal period three times suggests the formatting rule")
  func trailingPeriodRule() {
    let corrections = [
      correction("Ship it.", "Ship it"),
      correction("Sounds good.", "Sounds good"),
      correction("On my way.", "On my way"),
    ]
    let suggestions = StyleProfileLearner.suggest(corrections: corrections, records: [])
    #expect(
      suggestions.contains(
        LearnedRule(kind: .formatting, pattern: LearnedRule.noTerminalPeriod, replacement: nil, evidence: 3)))
  }

  @Test("Existing rules are not re-suggested; evidence is case-insensitive")
  func dedupeAgainstExisting() {
    let corrections = [correction("Gonna", "going to"), correction("gonna", "going to")]
    let existing = [LearnedRule(kind: .replacement, pattern: "gonna", replacement: "going to", evidence: 5)]
    let suggestions = StyleProfileLearner.suggest(
      corrections: corrections, records: [], existing: existing)
    #expect(suggestions.isEmpty)
  }

  @Test("Too little evidence yields nothing")
  func noEvidence() {
    #expect(StyleProfileLearner.suggest(corrections: [correction("a", "b")], records: []).isEmpty)
  }
}

@Suite("LearnedRules in cleanup")
struct LearnedRulesCleanupTests {
  @Test("Approved rules apply: extra filler, replacement, no terminal period")
  func rulesApply() {
    let rules = LearnedRules(
      approved: [
        LearnedRule(kind: .filler, pattern: "basically", replacement: nil, evidence: 3),
        LearnedRule(kind: .replacement, pattern: "gonna", replacement: "going to", evidence: 2),
        LearnedRule(kind: .formatting, pattern: LearnedRule.noTerminalPeriod, replacement: nil, evidence: 3),
      ])
    let cleaner = TranscriptCleaner(learnedRules: rules)
    #expect(cleaner.clean("Basically we're gonna ship it.").text == "We're going to ship it")
  }

  @Test("Replacement matches whole words only and keeps leading capitalization")
  func wholeWordReplacement() {
    let rules = LearnedRules(approved: [
      LearnedRule(kind: .replacement, pattern: "jon", replacement: "John", evidence: 2)
    ])
    let cleaner = TranscriptCleaner(learnedRules: rules)
    #expect(cleaner.clean("Jon met Jonathan.").text == "John met Jonathan.")
  }

  @Test("Disabled learning leaves cleanup untouched even with approved rules")
  func disabled() {
    let rules = LearnedRules(
      approved: [LearnedRule(kind: .filler, pattern: "basically", replacement: nil, evidence: 3)],
      enabled: false)
    let cleaner = TranscriptCleaner(learnedRules: rules)
    #expect(cleaner.clean("Basically done.").text == "Basically done.")
  }
}

@Suite("FlowStore learned rules")
struct LearnedRuleStoreTests {
  @Test("Rules persist with status transitions and the schema reaches v3")
  func lifecycle() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-rules-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite", isDirectory: false)
    let store = try await FlowStore.open(at: url)
    #expect(await store.schemaVersion() == 3)

    let rule = LearnedRule(kind: .replacement, pattern: "gonna", replacement: "going to", evidence: 2)
    try await store.upsertSuggestedRule(rule)
    try await store.upsertSuggestedRule(
      LearnedRule(kind: .replacement, pattern: "gonna", replacement: "going to", evidence: 4))
    let suggested = try await store.learnedRules(status: .suggested)
    #expect(suggested.count == 1)
    #expect(suggested.first?.rule.evidence == 4, "re-suggesting refreshes evidence, no duplicate")

    try await store.setRuleStatus(id: suggested[0].id, status: .approved)
    #expect(try await store.learnedRules(status: .suggested).isEmpty)
    #expect(try await store.learnedRules(status: .approved).map(\.rule.pattern) == ["gonna"])
    await store.close()
  }
}
