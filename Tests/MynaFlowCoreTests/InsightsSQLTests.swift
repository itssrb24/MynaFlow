import Foundation
import Testing

@testable import MynaFlowCore

@Suite("FlowStore insights aggregates")
struct InsightsSQLTests {
  private let base = Date(timeIntervalSince1970: 1_789_486_200)
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func record(
    words: Int, seconds: Double, at offset: TimeInterval, app: String?, engine: String,
    fallback: Bool = false, style: String? = nil, ms: Int
  ) -> DictationRecord {
    let text = Array(repeating: "w", count: words).joined(separator: " ")
    return DictationRecord(
      timestamp: base.addingTimeInterval(offset), rawTranscript: text, cleanedText: text,
      finalText: text, styleApplied: style, engineUsed: engine, fallbackOccurred: fallback,
      durationSeconds: seconds, wordCount: words, targetApp: app, insertionMethod: .ax,
      processingMs: ms)
  }

  @Test("SQL-side aggregation equals the pure aggregator on the same rows")
  func sqlMatchesPure() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-insights-sql-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite", isDirectory: false)
    let store = try await FlowStore.open(at: url)
    let rows = [
      record(words: 10, seconds: 5, at: 0, app: "com.apple.Notes", engine: "parakeet", ms: 300),
      record(words: 30, seconds: 15, at: -10, app: "com.google.Chrome", engine: "apple", fallback: true, style: "Formal", ms: 500),
      record(words: 5, seconds: 3, at: -20, app: "com.google.Chrome", engine: "apple", style: "Formal", ms: 100),
      record(words: 5, seconds: 3, at: -86_400 * 2, app: nil, engine: "apple", style: "Casual", ms: 900),
      record(words: 40, seconds: 20, at: -86_400 * 10, app: "com.apple.Notes", engine: "apple", ms: 200),
      record(words: 99, seconds: 9, at: -86_400 * 30, app: "com.apple.Notes", engine: "apple", ms: 250),
    ]
    for row in rows { try await store.insert(row) }

    for period in InsightsPeriod.allCases {
      let pure = InsightsAggregator.aggregate(rows, typingWPM: 40, now: base, calendar: calendar, period: period)
      let sql = try await store.insights(typingWPM: 40, now: base, calendar: calendar, period: period)
      #expect(sql == pure, "period \(period)")
    }
    await store.close()
  }
}
