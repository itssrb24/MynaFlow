import Foundation
import Testing

@testable import MynaFlowCore

@Suite("InsightsAggregator")
struct InsightsAggregatorTests {
  private let base = Date(timeIntervalSince1970: 1_789_486_200)  // 2026-09-16 15:30 UTC
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func record(
    words: Int, seconds: Double, at offset: TimeInterval = 0, app: String? = "com.apple.Notes",
    engine: String = "apple", fallback: Bool = false, style: String? = nil, ms: Int = 400
  ) -> DictationRecord {
    let text = Array(repeating: "w", count: words).joined(separator: " ")
    return DictationRecord(
      timestamp: base.addingTimeInterval(offset), rawTranscript: text, cleanedText: text,
      finalText: text, styleApplied: style, engineUsed: engine, fallbackOccurred: fallback,
      durationSeconds: seconds, wordCount: words, targetApp: app, insertionMethod: .ax,
      processingMs: ms)
  }

  @Test("Empty history yields zeroed insights without dividing by zero")
  func empty() {
    let insights = InsightsAggregator.aggregate([], typingWPM: 40, now: base, calendar: calendar)
    #expect(insights.totalWords == 0)
    #expect(insights.totalDictations == 0)
    #expect(insights.speakingWPM == 0)
    #expect(insights.timeSavedSeconds == 0)
    #expect(insights.fallbackRate == 0)
    #expect(insights.averageProcessingMs == 0)
    #expect(insights.dailyWords.count == 14)
    #expect(insights.dailyWords.allSatisfy { $0.words == 0 })
  }

  @Test("Totals, speaking pace, and time saved against typing speed")
  func totals() {
    // 120 words in 60 s of speech = 120 WPM speaking. At 40 WPM typing that
    // would take 180 s, so 120 s saved.
    let records = [record(words: 80, seconds: 40), record(words: 40, seconds: 20, at: -60)]
    let insights = InsightsAggregator.aggregate(records, typingWPM: 40, now: base, calendar: calendar)
    #expect(insights.totalWords == 120)
    #expect(insights.totalDictations == 2)
    #expect(insights.totalDictationSeconds == 60)
    #expect(insights.speakingWPM == 120)
    #expect(insights.timeSavedSeconds == 120)
  }

  @Test("Top apps ranked by words, engine split and fallback rate, style usage")
  func breakdowns() {
    let records = [
      record(words: 10, seconds: 5, app: "com.apple.Notes", engine: "parakeet"),
      record(words: 30, seconds: 15, at: -10, app: "com.google.Chrome", engine: "apple", fallback: true, style: "Formal"),
      record(words: 5, seconds: 3, at: -20, app: "com.google.Chrome", engine: "apple", style: "Formal"),
      record(words: 5, seconds: 3, at: -30, app: nil, engine: "apple", style: "Casual"),
    ]
    let insights = InsightsAggregator.aggregate(records, typingWPM: 40, now: base, calendar: calendar)
    #expect(insights.topApps.map(\.bundleID) == ["com.google.Chrome", "com.apple.Notes"])
    #expect(insights.topApps.first?.words == 35)
    #expect(insights.engineSplit == [("apple", 3), ("parakeet", 1)].map { EngineShare(engine: $0.0, count: $0.1) })
    #expect(insights.fallbackRate == 0.25)
    #expect(insights.styleUsage == [StyleUsage(style: "Formal", count: 2), StyleUsage(style: "Casual", count: 1)])
  }

  @Test("Latency average and p95")
  func latency() {
    let records = (1...20).map { record(words: 1, seconds: 1, at: -Double($0), ms: $0 * 10) }
    let insights = InsightsAggregator.aggregate(records, typingWPM: 40, now: base, calendar: calendar)
    #expect(insights.averageProcessingMs == 105)
    #expect(insights.p95ProcessingMs == 190)
  }

  @Test("Daily activity covers the last 14 days ending today, oldest first")
  func daily() {
    let records = [
      record(words: 7, seconds: 3),
      record(words: 3, seconds: 2, at: -86_400 * 2),
      record(words: 99, seconds: 9, at: -86_400 * 30),  // outside the window
    ]
    let insights = InsightsAggregator.aggregate(records, typingWPM: 40, now: base, calendar: calendar)
    #expect(insights.dailyWords.count == 14)
    #expect(insights.dailyWords.last?.words == 7)
    #expect(insights.dailyWords[11].words == 3)
    #expect(insights.dailyWords.map(\.words).reduce(0, +) == 10)
    #expect(insights.dailyWords.first!.day < insights.dailyWords.last!.day)
  }

  @Test("Period filter restricts to a window")
  func periods() {
    let records = [record(words: 5, seconds: 1), record(words: 50, seconds: 1, at: -86_400 * 10)]
    let week = InsightsAggregator.aggregate(
      records, typingWPM: 40, now: base, calendar: calendar, period: .week)
    #expect(week.totalWords == 5)
    let all = InsightsAggregator.aggregate(records, typingWPM: 40, now: base, calendar: calendar)
    #expect(all.totalWords == 55)
  }
}

@Suite("CorrectionDetector")
struct CorrectionDetectorTests {
  @Test("Edit inside the inserted region yields the before/after pair")
  func editDetected() {
    let before = "Meeting notes: Ship the kubernetes migration on Friday."
    let after = "Meeting notes: Ship the Kubernetes migration on Friday."
    let pair = CorrectionDetector.detect(
      before: before, after: after, inserted: "Ship the kubernetes migration on Friday.")
    #expect(pair?.before == "kubernetes")
    #expect(pair?.after == "Kubernetes")
  }

  @Test("Multi-word replacement is captured whole")
  func multiWord() {
    let before = "I met Jon Smith today."
    let after = "I met John Smyth today."
    let pair = CorrectionDetector.detect(before: before, after: after, inserted: "I met Jon Smith today.")
    #expect(pair?.before == "Jon Smith")
    #expect(pair?.after == "John Smyth")
  }

  @Test("Edits outside the inserted region are ignored")
  func outsideIgnored() {
    let before = "Intro. Ship it now."
    let after = "Intro!! Ship it now."
    #expect(CorrectionDetector.detect(before: before, after: after, inserted: "Ship it now.") == nil)
  }

  @Test("Unchanged text, or text where the insertion vanished entirely, yields nil")
  func nilCases() {
    #expect(CorrectionDetector.detect(before: "a b c", after: "a b c", inserted: "b") == nil)
    #expect(CorrectionDetector.detect(before: "hello world", after: "", inserted: "world") == nil)
  }

  @Test("Candidate terms are the changed words in the corrected text")
  func candidates() {
    let pair = CorrectionPair(before: "kubernetes cluster", after: "Kubernetes cluster")
    #expect(CorrectionDetector.candidateTerms(from: pair) == ["Kubernetes"])
    let phrase = CorrectionPair(before: "Jon Smith", after: "John Smyth")
    #expect(CorrectionDetector.candidateTerms(from: phrase) == ["John Smyth"])
  }
}

@Suite("FlowStore vocabulary + corrections")
struct VocabularyStoreTests {
  private func makeStore() async throws -> FlowStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-vocab-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite", isDirectory: false)
    return try await FlowStore.open(at: url)
  }

  @Test("Vocabulary terms add, dedupe case-insensitively, list, and remove")
  func vocabulary() async throws {
    let store = try await makeStore()
    try await store.addVocabularyTerm("Kubernetes", source: .manual)
    try await store.addVocabularyTerm("kubernetes", source: .promoted)
    try await store.addVocabularyTerm("GRDB", source: .manual)
    let terms = try await store.vocabularyTerms()
    #expect(terms.map(\.term) == ["GRDB", "Kubernetes"])
    try await store.removeVocabularyTerm("GRDB")
    #expect(try await store.vocabularyTerms().map(\.term) == ["Kubernetes"])
    await store.close()
  }

  @Test("Corrections log as candidates and resolve to accepted or dismissed")
  func corrections() async throws {
    let store = try await makeStore()
    let dictation = DictationRecord(
      rawTranscript: "x", cleanedText: "x", finalText: "x", engineUsed: "apple",
      durationSeconds: 1, wordCount: 1, insertionMethod: .ax, processingMs: 1)
    try await store.insert(dictation)
    let correction = try await store.logCorrection(
      CorrectionPair(before: "jon", after: "John"), dictationID: dictation.id)
    #expect(try await store.pendingCorrections().map(\.id) == [correction.id])
    try await store.resolveCorrection(id: correction.id, status: .accepted)
    #expect(try await store.pendingCorrections().isEmpty)
    await store.close()
  }
}
