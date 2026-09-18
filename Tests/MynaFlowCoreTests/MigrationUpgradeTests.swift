import Foundation
import SQLite3
import Testing

@testable import MynaFlowCore

/// Upgrades run against real user data on every update, and a failure here
/// looks to the user exactly like losing everything they have ever dictated.
/// Every other store test opens a brand-new file, so all six migrations
/// always run against empty tables — these start from a populated old one.
@Suite("Schema upgrades")
struct MigrationUpgradeTests {
  private let transient = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)

  /// Builds a database stamped at `version` with the migrations of the day,
  /// then puts a dictation and a style in it, the way a real user would have.
  private func makeLegacyDatabase(version: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-upgrade-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var handle: OpaquePointer?
    #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
    defer { sqlite3_close_v2(handle) }

    for statements in FlowStore.migrations.prefix(version) {
      for statement in statements {
        #expect(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
      }
    }
    #expect(sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK)

    let insert = """
      INSERT INTO dictations (
        id, timestamp, raw_transcript, cleaned_text, final_text, engine_used,
        fallback_occurred, duration_seconds, word_count, insertion_method, processing_ms
      ) VALUES ('\(UUID().uuidString)', 1700000000, 'um hello', 'Hello.', 'Hello.',
        'apple', 0, 1.5, 1, 'ax', 400)
      """
    #expect(sqlite3_exec(handle, insert, nil, nil, nil) == SQLITE_OK)
    return url
  }

  @Test("A populated v4 database upgrades without losing anything")
  func upgradesFromV4() async throws {
    let url = try makeLegacyDatabase(version: 4)

    let store = try await FlowStore.open(at: url)
    #expect(await store.schemaVersion() == FlowStore.migrations.count)

    // The dictation survives, and the column added since reads as absent
    // rather than breaking the row.
    let rows = try await store.recentDictations(limit: 10)
    #expect(rows.count == 1)
    #expect(rows.first?.finalText == "Hello.")
    #expect(rows.first?.insertionDiagnostics == nil)

    // Upgrading must not re-seed the built-in styles on top of the existing.
    let styles = try await store.styles()
    #expect(styles.count == Set(styles.map(\.name)).count, "built-in styles were duplicated")
    #expect(styles.contains { $0.name == "Casual" })

    // And the new tables are usable immediately.
    try await store.upsertAppRule(AppRule(bundleID: "com.apple.TextEdit", terminalPeriod: false))
    #expect(try await store.appRule(for: "com.apple.TextEdit")?.terminalPeriod == false)
    await store.close()
  }

  @Test("Opening an already-current database changes nothing")
  func idempotentOnCurrent() async throws {
    let url = try makeLegacyDatabase(version: FlowStore.migrations.count)
    let store = try await FlowStore.open(at: url)
    #expect(await store.schemaVersion() == FlowStore.migrations.count)
    #expect(try await store.recentDictations(limit: 10).count == 1)
    await store.close()

    // Re-opening is the common case: it must stay stable, and must not seed
    // a second set of built-ins.
    let reopened = try await FlowStore.open(at: url)
    let styles = try await reopened.styles()
    #expect(styles.count == Set(styles.map(\.name)).count)
    await reopened.close()
  }
}
