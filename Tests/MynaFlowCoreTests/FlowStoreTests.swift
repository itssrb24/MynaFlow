import Foundation
import Testing

@testable import MynaFlowCore

@Suite("FlowStore")
struct FlowStoreTests {
  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-store-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite", isDirectory: false)
  }

  private func makeRecord(
    id: UUID = UUID(),
    timestamp: Date = Date(timeIntervalSince1970: 1_750_000_000),
    targetApp: String? = "com.apple.TextEdit"
  ) -> DictationRecord {
    DictationRecord(
      id: id,
      timestamp: timestamp,
      rawTranscript: "um so this is is a test",
      cleanedText: "So this is a test.",
      finalText: "So this is a test.",
      styleApplied: nil,
      engineUsed: "apple",
      fallbackOccurred: false,
      durationSeconds: 3.2,
      wordCount: 5,
      targetApp: targetApp,
      insertionMethod: .ax,
      processingMs: 412
    )
  }

  @Test("Opening a fresh store migrates to the latest schema and sets 0600 permissions")
  func freshStoreMigratesAndProtectsFile() async throws {
    let url = temporaryDatabaseURL()
    let store = try await FlowStore.open(at: url)
    let version = await store.schemaVersion()
    #expect(version == 2)

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o077 == 0, "database must be owner-only")
    await store.close()
  }

  @Test("Dictation record round-trips through insert and fetch")
  func recordRoundTrip() async throws {
    let url = temporaryDatabaseURL()
    let store = try await FlowStore.open(at: url)
    let record = makeRecord()
    try await store.insert(record)

    let fetched = try await store.recentDictations(limit: 10)
    #expect(fetched == [record])
    await store.close()
  }

  @Test("Recent dictations are reverse-chronological and respect the limit")
  func recentOrderingAndLimit() async throws {
    let url = temporaryDatabaseURL()
    let store = try await FlowStore.open(at: url)
    let base = Date(timeIntervalSince1970: 1_750_000_000)
    let old = makeRecord(timestamp: base)
    let mid = makeRecord(timestamp: base.addingTimeInterval(60))
    let new = makeRecord(timestamp: base.addingTimeInterval(120))
    for record in [mid, old, new] { try await store.insert(record) }

    let recent = try await store.recentDictations(limit: 2)
    #expect(recent.map(\.id) == [new.id, mid.id])
    await store.close()
  }

  @Test("Data survives close and reopen")
  func persistenceAcrossReopen() async throws {
    let url = temporaryDatabaseURL()
    let record = makeRecord()
    do {
      let store = try await FlowStore.open(at: url)
      try await store.insert(record)
      await store.close()
    }
    let reopened = try await FlowStore.open(at: url)
    let fetched = try await reopened.recentDictations(limit: 1)
    #expect(fetched == [record])
    await reopened.close()
  }

  @Test("Nullable fields round-trip as NULL")
  func nullableFields() async throws {
    let url = temporaryDatabaseURL()
    let store = try await FlowStore.open(at: url)
    var record = makeRecord(targetApp: nil)
    record.styleApplied = nil
    try await store.insert(record)
    let fetched = try #require(try await store.recentDictations(limit: 1).first)
    #expect(fetched.targetApp == nil)
    #expect(fetched.styleApplied == nil)
    await store.close()
  }

  @Test("Settings key-value store round-trips and overwrites")
  func settingsRoundTrip() async throws {
    let url = temporaryDatabaseURL()
    let store = try await FlowStore.open(at: url)
    #expect(try await store.setting(forKey: "typing_wpm") == nil)
    try await store.setSetting("40", forKey: "typing_wpm")
    #expect(try await store.setting(forKey: "typing_wpm") == "40")
    try await store.setSetting("72", forKey: "typing_wpm")
    #expect(try await store.setting(forKey: "typing_wpm") == "72")
    await store.close()
  }

  @Test("Built-in styles are seeded exactly once")
  func builtinStylesSeeded() async throws {
    let url = temporaryDatabaseURL()
    let store = try await FlowStore.open(at: url)
    let styles = try await store.styles()
    #expect(styles.filter(\.builtin).map(\.name).sorted() == ["Casual", "Concise", "Formal"])
    await store.close()

    // Reopen must not duplicate the seed.
    let reopened = try await FlowStore.open(at: url)
    let again = try await reopened.styles()
    #expect(again.count == styles.count)
    await reopened.close()
  }
}
