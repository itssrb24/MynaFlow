import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct FlowStoreError: Error, CustomStringConvertible, Sendable {
  public let message: String
  public var description: String { "FlowStore: \(message)" }
}

/// Plain-SQLite persistence for Myna Flow. Single writer, WAL, owner-only file
/// permissions. Intentionally unencrypted (dictation text is the user's own
/// prose on their own disk); privacy comes from 0600 + local-only design.
public actor FlowStore {
  private var handle: OpaquePointer?
  private let url: URL

  private init(url: URL) {
    self.url = url
  }

  public static func open(at url: URL) async throws -> FlowStore {
    let store = FlowStore(url: url)
    try await store.openDatabase()
    return store
  }

  public func close() {
    if let handle {
      sqlite3_close_v2(handle)
    }
    handle = nil
  }

  public func schemaVersion() -> Int {
    (try? scalarInt("PRAGMA user_version")) ?? 0
  }

  // MARK: - Dictations

  public func insert(_ record: DictationRecord) throws {
    try run(
      """
      INSERT INTO dictations (
        id, timestamp, raw_transcript, cleaned_text, final_text, style_applied,
        engine_used, fallback_occurred, duration_seconds, word_count,
        target_app, insertion_method, processing_ms
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, record.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, record.rawTranscript, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, record.cleanedText, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, record.finalText, -1, sqliteTransient)
        bindOptionalText(statement, 6, record.styleApplied)
        sqlite3_bind_text(statement, 7, record.engineUsed, -1, sqliteTransient)
        sqlite3_bind_int(statement, 8, record.fallbackOccurred ? 1 : 0)
        sqlite3_bind_double(statement, 9, record.durationSeconds)
        sqlite3_bind_int(statement, 10, Int32(record.wordCount))
        bindOptionalText(statement, 11, record.targetApp)
        sqlite3_bind_text(statement, 12, record.insertionMethod.rawValue, -1, sqliteTransient)
        sqlite3_bind_int(statement, 13, Int32(record.processingMs))
      })
  }

  public func recentDictations(limit: Int) throws -> [DictationRecord] {
    try query(
      """
      SELECT id, timestamp, raw_transcript, cleaned_text, final_text, style_applied,
             engine_used, fallback_occurred, duration_seconds, word_count,
             target_app, insertion_method, processing_ms
      FROM dictations ORDER BY timestamp DESC LIMIT ?1
      """,
      bind: { sqlite3_bind_int($0, 1, Int32(limit)) },
      row: readDictationRecord)
  }

  // MARK: - Settings

  public func setting(forKey key: String) throws -> String? {
    let rows = try query(
      "SELECT value FROM settings WHERE key = ?1",
      bind: { sqlite3_bind_text($0, 1, key, -1, sqliteTransient) },
      row: { statement in columnText(statement, 0) ?? "" })
    return rows.first
  }

  public func setSetting(_ value: String, forKey key: String) throws {
    try run(
      "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
      bind: { statement in
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, sqliteTransient)
      })
  }

  // MARK: - Styles

  public func styles() throws -> [Style] {
    try query(
      """
      SELECT id, name, prompt, builtin, hotkey_slot, created_at, examples
      FROM styles ORDER BY created_at
      """,
      bind: { _ in },
      row: Self.readStyle)
  }

  /// The style bound to a hotkey slot (1–5), if any.
  public func style(forSlot slot: Int) throws -> Style? {
    try query(
      """
      SELECT id, name, prompt, builtin, hotkey_slot, created_at, examples
      FROM styles WHERE hotkey_slot = ?1 LIMIT 1
      """,
      bind: { sqlite3_bind_int($0, 1, Int32(slot)) },
      row: Self.readStyle
    ).first
  }

  /// Insert or update by id.
  public func saveStyle(_ style: Style) throws {
    let examples =
      String(data: (try? JSONEncoder().encode(style.examples)) ?? Data("[]".utf8), encoding: .utf8)
      ?? "[]"
    try run(
      """
      INSERT INTO styles (id, name, prompt, builtin, hotkey_slot, created_at, examples)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      ON CONFLICT(id) DO UPDATE SET
        name = ?2, prompt = ?3, hotkey_slot = ?5, examples = ?7
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, style.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, style.name, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, style.prompt, -1, sqliteTransient)
        sqlite3_bind_int(statement, 4, style.builtin ? 1 : 0)
        if let slot = style.hotkeySlot {
          sqlite3_bind_int(statement, 5, Int32(slot))
        } else {
          sqlite3_bind_null(statement, 5)
        }
        sqlite3_bind_double(statement, 6, style.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 7, examples, -1, sqliteTransient)
      })
  }

  public func deleteStyle(id: UUID) throws {
    try run(
      "DELETE FROM styles WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, sqliteTransient) })
  }

  private static func readStyle(_ statement: OpaquePointer) -> Style {
    let examplesJSON = columnText(statement, 6) ?? "[]"
    let examples =
      (try? JSONDecoder().decode([StyleExample].self, from: Data(examplesJSON.utf8))) ?? []
    return Style(
      id: UUID(uuidString: columnText(statement, 0) ?? "") ?? UUID(),
      name: columnText(statement, 1) ?? "",
      prompt: columnText(statement, 2) ?? "",
      builtin: sqlite3_column_int(statement, 3) != 0,
      hotkeySlot: sqlite3_column_type(statement, 4) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int(statement, 4)),
      examples: examples,
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)))
  }

  // MARK: - Open + migrations

  private func openDatabase() throws {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open failure"
      sqlite3_close_v2(database)
      throw FlowStoreError(message: message)
    }
    handle = database

    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try executeSQL("PRAGMA journal_mode=WAL")
    try executeSQL("PRAGMA foreign_keys=ON")
    try migrate()
  }

  /// Ordered migrations; each runs in a transaction and bumps user_version.
  /// Append-only — never edit a shipped migration.
  private static let migrations: [[String]] = [
    // v1
    [
      """
      CREATE TABLE dictations (
        id TEXT PRIMARY KEY,
        timestamp REAL NOT NULL,
        raw_transcript TEXT NOT NULL,
        cleaned_text TEXT NOT NULL,
        final_text TEXT NOT NULL,
        style_applied TEXT,
        engine_used TEXT NOT NULL,
        fallback_occurred INTEGER NOT NULL DEFAULT 0,
        duration_seconds REAL NOT NULL,
        word_count INTEGER NOT NULL,
        target_app TEXT,
        insertion_method TEXT NOT NULL,
        processing_ms INTEGER NOT NULL
      )
      """,
      "CREATE INDEX idx_dictations_timestamp ON dictations(timestamp)",
      "CREATE INDEX idx_dictations_target_app ON dictations(target_app)",
      """
      CREATE TABLE styles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        prompt TEXT NOT NULL,
        builtin INTEGER NOT NULL DEFAULT 0,
        hotkey_slot INTEGER,
        created_at REAL NOT NULL
      )
      """,
      """
      CREATE TABLE vocabulary (
        id TEXT PRIMARY KEY,
        term TEXT NOT NULL UNIQUE,
        added_at REAL NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual'
      )
      """,
      """
      CREATE TABLE corrections (
        id TEXT PRIMARY KEY,
        dictation_id TEXT REFERENCES dictations(id),
        before_text TEXT NOT NULL,
        after_text TEXT NOT NULL,
        observed_at REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'candidate'
      )
      """,
      "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    ],
    // v2: custom styles carry optional example input/output pairs (JSON).
    [
      "ALTER TABLE styles ADD COLUMN examples TEXT NOT NULL DEFAULT '[]'"
    ],
  ]

  private func migrate() throws {
    let current = try scalarInt("PRAGMA user_version")
    guard current < Self.migrations.count else { return }
    for (index, statements) in Self.migrations.enumerated() where index >= current {
      try executeSQL("BEGIN IMMEDIATE")
      do {
        for statement in statements {
          try executeSQL(statement)
        }
        try executeSQL("PRAGMA user_version = \(index + 1)")
        try executeSQL("COMMIT")
      } catch {
        try? executeSQL("ROLLBACK")
        throw error
      }
    }
    try seedBuiltinStylesIfNeeded()
  }

  private func seedBuiltinStylesIfNeeded() throws {
    let count = try scalarInt("SELECT COUNT(*) FROM styles WHERE builtin = 1")
    guard count == 0 else { return }
    let now = Date().timeIntervalSince1970
    let builtins: [(name: String, prompt: String, slot: Int)] = [
      (
        "Casual",
        "Rewrite the text in a relaxed, conversational tone. Use contractions. "
          + "Keep the meaning and all facts exactly the same.",
        1
      ),
      (
        "Formal",
        "Rewrite the text in a professional tone with complete sentences and no "
          + "contractions. Keep the meaning and all facts exactly the same.",
        2
      ),
      (
        "Concise",
        "Rewrite the text to be shorter. Cut redundancy but preserve every point "
          + "and the original tone. Keep the meaning exactly the same.",
        3
      ),
    ]
    for style in builtins {
      try run(
        "INSERT INTO styles (id, name, prompt, builtin, hotkey_slot, created_at) VALUES (?1, ?2, ?3, 1, ?4, ?5)",
        bind: { statement in
          sqlite3_bind_text(statement, 1, UUID().uuidString, -1, sqliteTransient)
          sqlite3_bind_text(statement, 2, style.name, -1, sqliteTransient)
          sqlite3_bind_text(statement, 3, style.prompt, -1, sqliteTransient)
          sqlite3_bind_int(statement, 4, Int32(style.slot))
          sqlite3_bind_double(statement, 5, now)
        })
    }
  }

  // MARK: - SQLite plumbing

  private func requireHandle() throws -> OpaquePointer {
    guard let handle else { throw FlowStoreError(message: "database is closed") }
    return handle
  }

  /// DDL / pragmas only — everything with user data goes through `run`/`query`
  /// with bound parameters.
  private func executeSQL(_ sql: String) throws {
    let database = try requireHandle()
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
      sqlite3_free(errorMessage)
      throw FlowStoreError(message: "\(message) — while executing: \(sql.prefix(80))")
    }
  }

  private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
    let database = try requireHandle()
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw FlowStoreError(message: String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    bind(statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw FlowStoreError(message: String(cString: sqlite3_errmsg(database)))
    }
  }

  private func query<Row>(
    _ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) throws -> Row
  ) throws -> [Row] {
    let database = try requireHandle()
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw FlowStoreError(message: String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    bind(statement)
    var rows: [Row] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_ROW {
        rows.append(try row(statement))
      } else if status == SQLITE_DONE {
        return rows
      } else {
        throw FlowStoreError(message: String(cString: sqlite3_errmsg(database)))
      }
    }
  }

  private func scalarInt(_ sql: String) throws -> Int {
    let values = try query(sql, bind: { _ in }, row: { Int(sqlite3_column_int64($0, 0)) })
    return values.first ?? 0
  }

  private func readDictationRecord(_ statement: OpaquePointer) throws -> DictationRecord {
    guard
      let idText = columnText(statement, 0),
      let id = UUID(uuidString: idText),
      let method = InsertionMethod(rawValue: columnText(statement, 11) ?? "")
    else {
      throw FlowStoreError(message: "malformed dictation row")
    }
    return DictationRecord(
      id: id,
      timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      rawTranscript: columnText(statement, 2) ?? "",
      cleanedText: columnText(statement, 3) ?? "",
      finalText: columnText(statement, 4) ?? "",
      styleApplied: columnText(statement, 5),
      engineUsed: columnText(statement, 6) ?? "",
      fallbackOccurred: sqlite3_column_int(statement, 7) != 0,
      durationSeconds: sqlite3_column_double(statement, 8),
      wordCount: Int(sqlite3_column_int(statement, 9)),
      targetApp: columnText(statement, 10),
      insertionMethod: method,
      processingMs: Int(sqlite3_column_int(statement, 12)))
  }
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
  guard sqlite3_column_type(statement, index) != SQLITE_NULL,
    let cString = sqlite3_column_text(statement, index)
  else { return nil }
  return String(cString: cString)
}

private func bindOptionalText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
  if let value {
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
  } else {
    sqlite3_bind_null(statement, index)
  }
}
