import Foundation
import Testing

@testable import MynaFlowCore

@Suite("DeletionRange")
struct DeletionRangeTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  // 2026-09-16 15:30:00 UTC
  private let now = Date(timeIntervalSince1970: 1_789_486_200)

  @Test("Cutoffs match browser-history semantics")
  func cutoffs() {
    #expect(DeletionRange.lastHour.cutoff(now: now, calendar: calendar) == now.addingTimeInterval(-3_600))
    #expect(
      DeletionRange.today.cutoff(now: now, calendar: calendar)
        == calendar.startOfDay(for: now))
    #expect(
      DeletionRange.pastWeek.cutoff(now: now, calendar: calendar)
        == calendar.date(byAdding: .day, value: -7, to: now))
    #expect(
      DeletionRange.pastMonth.cutoff(now: now, calendar: calendar)
        == calendar.date(byAdding: .month, value: -1, to: now))
    #expect(DeletionRange.allTime.cutoff(now: now, calendar: calendar) == .distantPast)
  }
}

@Suite("FlowStore history queries")
struct HistoryQueryTests {
  private func makeStore() async throws -> FlowStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-history-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite", isDirectory: false)
    return try await FlowStore.open(at: url)
  }

  private func record(
    _ text: String, at timestamp: Date, app: String? = "com.apple.TextEdit",
    engine: String = "apple", fallback: Bool = false
  ) -> DictationRecord {
    DictationRecord(
      timestamp: timestamp, rawTranscript: text, cleanedText: text, finalText: text,
      engineUsed: engine, fallbackOccurred: fallback, durationSeconds: 1,
      wordCount: text.split(separator: " ").count, targetApp: app,
      insertionMethod: .ax, processingMs: 100)
  }

  private let base = Date(timeIntervalSince1970: 1_789_486_200)

  @Test("Full-text search matches final text case-insensitively")
  func search() async throws {
    let store = try await makeStore()
    try await store.insert(record("Ship the Kubernetes migration", at: base))
    try await store.insert(record("Lunch at noon", at: base.addingTimeInterval(-60)))
    let hits = try await store.searchDictations(
      HistoryQuery(text: "kubernetes"), limit: 50)
    #expect(hits.map(\.finalText) == ["Ship the Kubernetes migration"])
    await store.close()
  }

  @Test("Filters by app, engine, and date range compose")
  func filters() async throws {
    let store = try await makeStore()
    try await store.insert(record("a", at: base, app: "com.apple.TextEdit", engine: "apple"))
    try await store.insert(
      record("b", at: base.addingTimeInterval(-100), app: "com.google.Chrome", engine: "parakeet"))
    try await store.insert(
      record("c", at: base.addingTimeInterval(-100_000), app: "com.google.Chrome", engine: "apple"))

    let chrome = try await store.searchDictations(
      HistoryQuery(targetApp: "com.google.Chrome"), limit: 50)
    #expect(chrome.map(\.finalText) == ["b", "c"])

    let parakeet = try await store.searchDictations(HistoryQuery(engine: "parakeet"), limit: 50)
    #expect(parakeet.map(\.finalText) == ["b"])

    let recent = try await store.searchDictations(
      HistoryQuery(since: base.addingTimeInterval(-1_000)), limit: 50)
    #expect(recent.map(\.finalText) == ["a", "b"])

    let combined = try await store.searchDictations(
      HistoryQuery(targetApp: "com.google.Chrome", since: base.addingTimeInterval(-1_000)),
      limit: 50)
    #expect(combined.map(\.finalText) == ["b"])
    await store.close()
  }

  @Test("Ranged deletion removes only rows at or after the cutoff")
  func rangedDeletion() async throws {
    let store = try await makeStore()
    try await store.insert(record("new", at: base))
    try await store.insert(record("old", at: base.addingTimeInterval(-10_000)))
    let deleted = try await store.deleteDictations(since: base.addingTimeInterval(-3_600))
    #expect(deleted == 1)
    let remaining = try await store.recentDictations(limit: 10)
    #expect(remaining.map(\.finalText) == ["old"])
    await store.close()
  }

  @Test("Single-entry deletion and distinct app listing")
  func singleDeleteAndApps() async throws {
    let store = try await makeStore()
    let one = record("one", at: base, app: "com.apple.Notes")
    try await store.insert(one)
    try await store.insert(record("two", at: base.addingTimeInterval(-1), app: "com.apple.Notes"))
    try await store.insert(record("three", at: base.addingTimeInterval(-2), app: nil))
    try await store.deleteDictation(id: one.id)
    #expect(try await store.recentDictations(limit: 10).count == 2)
    #expect(try await store.distinctTargetApps() == ["com.apple.Notes"])
    await store.close()
  }

  @Test("Updating final text and style after a re-polish")
  func updateFinalText() async throws {
    let store = try await makeStore()
    let entry = record("plain words", at: base)
    try await store.insert(entry)
    try await store.updateFinalText("Plain words, refined.", style: "Formal", forDictation: entry.id)
    let reloaded = try #require(try await store.recentDictations(limit: 1).first)
    #expect(reloaded.finalText == "Plain words, refined.")
    #expect(reloaded.styleApplied == "Formal")
    #expect(reloaded.cleanedText == "plain words", "cleaned text is immutable")
    await store.close()
  }
}
