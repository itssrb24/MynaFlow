import Foundation
import Testing

@testable import MynaFlowCore

@Suite("HistoryExporter")
struct HistoryExporterTests {
  private let record = DictationRecord(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
    rawTranscript: "um hello", cleanedText: "Hello.", finalText: "Hello.",
    engineUsed: "apple", durationSeconds: 1.5, wordCount: 1,
    targetApp: "com.apple.TextEdit", insertionMethod: .ax, processingMs: 420)

  @Test("Markdown has one heading per dictation with the final text under it")
  func markdown() {
    let text = HistoryExporter.markdown([record])
    #expect(text.hasPrefix("# Myna Flow history"))
    #expect(text.contains("## 2023-11-14T22:13:20Z · apple · com.apple.TextEdit"))
    #expect(text.contains("\nHello.\n"))
  }

  @Test("JSON is sorted-key, ISO-8601 and round-trips")
  func json() throws {
    let data = try HistoryExporter.export([record], as: .json)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"timestamp\" : \"2023-11-14T22:13:20Z\""))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode([DictationRecord].self, from: data)
    #expect(back == [record])
  }
}
