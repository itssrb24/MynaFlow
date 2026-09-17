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

  public var databaseURL: URL { url }

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

  // MARK: - App rules

  public func appRules() throws -> [AppRule] {
    try query(
      "SELECT bundle_id, cleanup_enabled, terminal_period, polish_style_id FROM app_rules ORDER BY bundle_id",
      bind: { _ in }, row: readAppRule)
  }

  public func appRule(for bundleID: String) throws -> AppRule? {
    try query(
      "SELECT bundle_id, cleanup_enabled, terminal_period, polish_style_id FROM app_rules WHERE bundle_id = ?1",
      bind: { sqlite3_bind_text($0, 1, bundleID, -1, sqliteTransient) }, row: readAppRule
    ).first
  }

  /// Insert-or-replace; an empty rule is removed instead of stored.
  public func upsertAppRule(_ rule: AppRule) throws {
    if rule.isEmpty {
      try deleteAppRule(bundleID: rule.bundleID)
      return
    }
    try run(
      """
      INSERT INTO app_rules (bundle_id, cleanup_enabled, terminal_period, polish_style_id, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(bundle_id) DO UPDATE SET
        cleanup_enabled = excluded.cleanup_enabled,
        terminal_period = excluded.terminal_period,
        polish_style_id = excluded.polish_style_id,
        updated_at = excluded.updated_at
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, rule.bundleID, -1, sqliteTransient)
        bindOptionalBool(statement, 2, rule.cleanupEnabled)
        bindOptionalBool(statement, 3, rule.terminalPeriod)
        bindOptionalText(statement, 4, rule.polishStyleID?.uuidString)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
      })
  }

  public func deleteAppRule(bundleID: String) throws {
    try run(
      "DELETE FROM app_rules WHERE bundle_id = ?1",
      bind: { sqlite3_bind_text($0, 1, bundleID, -1, sqliteTransient) })
  }

  private func bindOptionalBool(_ statement: OpaquePointer, _ index: Int32, _ value: Bool?) {
    if let value {
      sqlite3_bind_int(statement, index, value ? 1 : 0)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func columnOptionalBool(_ statement: OpaquePointer, _ index: Int32) -> Bool? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int(statement, index) != 0
  }

  private func readAppRule(_ statement: OpaquePointer) throws -> AppRule {
    AppRule(
      bundleID: columnText(statement, 0) ?? "",
      cleanupEnabled: columnOptionalBool(statement, 1),
      terminalPeriod: columnOptionalBool(statement, 2),
      polishStyleID: columnText(statement, 3).flatMap(UUID.init(uuidString:)))
  }

  // MARK: - Dictations

  public func insert(_ record: DictationRecord) throws {
    try run(
      """
      INSERT INTO dictations (
        id, timestamp, raw_transcript, cleaned_text, final_text, style_applied,
        engine_used, fallback_occurred, duration_seconds, word_count,
        target_app, insertion_method, processing_ms, insertion_diagnostics
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
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
        bindOptionalText(statement, 14, record.insertionDiagnostics)
      })
  }

  public func recentDictations(limit: Int) throws -> [DictationRecord] {
    try query(
      """
      SELECT \(Self.dictationColumns)
      FROM dictations ORDER BY timestamp DESC LIMIT ?1
      """,
      bind: { sqlite3_bind_int($0, 1, Int32(limit)) },
      row: readDictationRecord)
  }

  private static let dictationColumns = """
    id, timestamp, raw_transcript, cleaned_text, final_text, style_applied,
    engine_used, fallback_occurred, duration_seconds, word_count,
    target_app, insertion_method, processing_ms, insertion_diagnostics
    """

  /// Filtered, reverse-chronological history. Text search is a LIKE over
  /// the final text (FTS is a later migration if this proves slow).
  public func searchDictations(_ filter: HistoryQuery, limit: Int) throws -> [DictationRecord] {
    var clauses: [String] = []
    var binders: [(OpaquePointer, Int32) -> Void] = []
    if let text = filter.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
      clauses.append("final_text LIKE ?\(binders.count + 1) ESCAPE '\\'")
      let escaped =
        text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
      let pattern = "%\(escaped)%"
      binders.append { sqlite3_bind_text($0, $1, pattern, -1, sqliteTransient) }
    }
    if let app = filter.targetApp {
      clauses.append("target_app = ?\(binders.count + 1)")
      binders.append { sqlite3_bind_text($0, $1, app, -1, sqliteTransient) }
    }
    if let engine = filter.engine {
      clauses.append("engine_used = ?\(binders.count + 1)")
      binders.append { sqlite3_bind_text($0, $1, engine, -1, sqliteTransient) }
    }
    if let since = filter.since {
      clauses.append("timestamp >= ?\(binders.count + 1)")
      let value = since.timeIntervalSince1970
      binders.append { sqlite3_bind_double($0, $1, value) }
    }
    if let until = filter.until {
      clauses.append("timestamp <= ?\(binders.count + 1)")
      let value = until.timeIntervalSince1970
      binders.append { sqlite3_bind_double($0, $1, value) }
    }
    let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
    let limitIndex = binders.count + 1
    return try query(
      "SELECT \(Self.dictationColumns) FROM dictations \(whereClause) ORDER BY timestamp DESC LIMIT ?\(limitIndex)",
      bind: { statement in
        for (offset, binder) in binders.enumerated() {
          binder(statement, Int32(offset + 1))
        }
        sqlite3_bind_int(statement, Int32(limitIndex), Int32(limit))
      },
      row: readDictationRecord)
  }

  /// Deletes rows at or after `cutoff`; returns how many.
  @discardableResult
  public func deleteDictations(since cutoff: Date) throws -> Int {
    try run(
      "DELETE FROM dictations WHERE timestamp >= ?1",
      bind: { sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970) })
    return Int(sqlite3_changes(try requireHandle()))
  }

  public func deleteDictation(id: UUID) throws {
    try run(
      "DELETE FROM dictations WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, sqliteTransient) })
  }

  /// Bundle identifiers that appear in history, most frequent first.
  public func distinctTargetApps() throws -> [String] {
    try query(
      """
      SELECT target_app, COUNT(*) AS n FROM dictations
      WHERE target_app IS NOT NULL GROUP BY target_app ORDER BY n DESC, target_app
      """,
      bind: { _ in },
      row: { columnText($0, 0) ?? "" })
  }

  /// Re-polish result: final text and style change; cleaned text is immutable.
  public func updateFinalText(_ text: String, style: String?, forDictation id: UUID) throws {
    try run(
      "UPDATE dictations SET final_text = ?1, style_applied = ?2 WHERE id = ?3",
      bind: { statement in
        sqlite3_bind_text(statement, 1, text, -1, sqliteTransient)
        bindOptionalText(statement, 2, style)
        sqlite3_bind_text(statement, 3, id.uuidString, -1, sqliteTransient)
      })
  }

  // MARK: - Vocabulary

  /// Adds a term unless one already exists case-insensitively.
  public func addVocabularyTerm(_ term: String, source: VocabularySource) throws {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    try run(
      """
      INSERT INTO vocabulary (id, term, added_at, source)
      SELECT ?1, ?2, ?3, ?4
      WHERE NOT EXISTS (SELECT 1 FROM vocabulary WHERE lower(term) = lower(?2))
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, trimmed, -1, sqliteTransient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 4, source.rawValue, -1, sqliteTransient)
      })
  }

  public func removeVocabularyTerm(_ term: String) throws {
    try run(
      "DELETE FROM vocabulary WHERE lower(term) = lower(?1)",
      bind: { sqlite3_bind_text($0, 1, term, -1, sqliteTransient) })
  }

  public func vocabularyTerms() throws -> [VocabularyTerm] {
    try query(
      "SELECT id, term, added_at, source FROM vocabulary ORDER BY term COLLATE NOCASE",
      bind: { _ in },
      row: { statement in
        VocabularyTerm(
          id: UUID(uuidString: columnText(statement, 0) ?? "") ?? UUID(),
          term: columnText(statement, 1) ?? "",
          addedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
          source: VocabularySource(rawValue: columnText(statement, 3) ?? "") ?? .manual)
      })
  }

  // MARK: - Corrections

  @discardableResult
  public func logCorrection(_ pair: CorrectionPair, dictationID: UUID?) throws -> CorrectionRecord {
    let record = CorrectionRecord(
      id: UUID(), dictationID: dictationID, pair: pair, observedAt: Date(), status: .candidate)
    try run(
      """
      INSERT INTO corrections (id, dictation_id, before_text, after_text, observed_at, status)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, sqliteTransient)
        bindOptionalText(statement, 2, dictationID?.uuidString)
        sqlite3_bind_text(statement, 3, pair.before, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, pair.after, -1, sqliteTransient)
        sqlite3_bind_double(statement, 5, record.observedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 6, record.status.rawValue, -1, sqliteTransient)
      })
    return record
  }

  public func pendingCorrections() throws -> [CorrectionRecord] {
    try query(
      """
      SELECT id, dictation_id, before_text, after_text, observed_at, status
      FROM corrections WHERE status = 'candidate' ORDER BY observed_at DESC
      """,
      bind: { _ in },
      row: { statement in
        CorrectionRecord(
          id: UUID(uuidString: columnText(statement, 0) ?? "") ?? UUID(),
          dictationID: columnText(statement, 1).flatMap(UUID.init(uuidString:)),
          pair: CorrectionPair(
            before: columnText(statement, 2) ?? "", after: columnText(statement, 3) ?? ""),
          observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
          status: CorrectionStatus(rawValue: columnText(statement, 5) ?? "") ?? .candidate)
      })
  }

  public func resolveCorrection(id: UUID, status: CorrectionStatus) throws {
    try run(
      "UPDATE corrections SET status = ?1 WHERE id = ?2",
      bind: { statement in
        sqlite3_bind_text(statement, 1, status.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, sqliteTransient)
      })
  }

  // MARK: - Learned rules

  /// Inserts a suggestion, or refreshes the evidence of an existing one
  /// that is still merely suggested. Approved/rejected rules are never
  /// downgraded by a re-suggestion.
  public func upsertSuggestedRule(_ rule: LearnedRule) throws {
    let now = Date().timeIntervalSince1970
    try run(
      """
      INSERT INTO learned_rules (id, kind, pattern, replacement, evidence, status, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, 'suggested', ?6, ?6)
      ON CONFLICT(kind, pattern) DO UPDATE SET
        evidence = excluded.evidence, replacement = excluded.replacement, updated_at = excluded.updated_at
        WHERE learned_rules.status = 'suggested'
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, UUID().uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, rule.kind.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, rule.pattern.lowercased(), -1, sqliteTransient)
        bindOptionalText(statement, 4, rule.replacement)
        sqlite3_bind_int(statement, 5, Int32(rule.evidence))
        sqlite3_bind_double(statement, 6, now)
      })
  }

  public func learnedRules(status: LearnedRuleStatus) throws -> [StoredLearnedRule] {
    try query(
      """
      SELECT id, kind, pattern, replacement, evidence, status, updated_at
      FROM learned_rules WHERE status = ?1 ORDER BY evidence DESC, pattern
      """,
      bind: { sqlite3_bind_text($0, 1, status.rawValue, -1, sqliteTransient) },
      row: Self.readLearnedRule)
  }

  public func allLearnedRules() throws -> [StoredLearnedRule] {
    try query(
      "SELECT id, kind, pattern, replacement, evidence, status, updated_at FROM learned_rules",
      bind: { _ in }, row: Self.readLearnedRule)
  }

  public func setRuleStatus(id: UUID, status: LearnedRuleStatus) throws {
    try run(
      "UPDATE learned_rules SET status = ?1, updated_at = ?2 WHERE id = ?3",
      bind: { statement in
        sqlite3_bind_text(statement, 1, status.rawValue, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, id.uuidString, -1, sqliteTransient)
      })
  }

  private static func readLearnedRule(_ statement: OpaquePointer) -> StoredLearnedRule {
    StoredLearnedRule(
      id: UUID(uuidString: columnText(statement, 0) ?? "") ?? UUID(),
      rule: LearnedRule(
        kind: LearnedRule.Kind(rawValue: columnText(statement, 1) ?? "") ?? .filler,
        pattern: columnText(statement, 2) ?? "",
        replacement: columnText(statement, 3),
        evidence: Int(sqlite3_column_int(statement, 4))),
      status: LearnedRuleStatus(rawValue: columnText(statement, 5) ?? "") ?? .suggested,
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)))
  }

  /// All corrections regardless of status, for the learner.
  public func allCorrections() throws -> [CorrectionRecord] {
    try query(
      """
      SELECT id, dictation_id, before_text, after_text, observed_at, status
      FROM corrections ORDER BY observed_at DESC
      """,
      bind: { _ in },
      row: { statement in
        CorrectionRecord(
          id: UUID(uuidString: columnText(statement, 0) ?? "") ?? UUID(),
          dictationID: columnText(statement, 1).flatMap(UUID.init(uuidString:)),
          pair: CorrectionPair(
            before: columnText(statement, 2) ?? "", after: columnText(statement, 3) ?? ""),
          observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
          status: CorrectionStatus(rawValue: columnText(statement, 5) ?? "") ?? .candidate)
      })
  }

  // MARK: - Insights (aggregated in SQL so 100k rows never load into memory)

  public func insights(
    typingWPM: Double, now: Date = Date(), calendar: Calendar = .current,
    period: InsightsPeriod = .all
  ) throws -> Insights {
    let since = period.since(now: now, calendar: calendar)?.timeIntervalSince1970 ?? -Double.infinity
    let bind: (OpaquePointer) -> Void = { sqlite3_bind_double($0, 1, since) }

    struct Totals { var words = 0; var count = 0; var seconds = 0.0; var fallbacks = 0; var msSum = 0 }
    let totals = try query(
      """
      SELECT COALESCE(SUM(word_count),0), COUNT(*), COALESCE(SUM(duration_seconds),0),
             COALESCE(SUM(fallback_occurred),0), COALESCE(SUM(processing_ms),0)
      FROM dictations WHERE timestamp >= ?1
      """,
      bind: bind,
      row: { s in
        Totals(
          words: Int(sqlite3_column_int64(s, 0)), count: Int(sqlite3_column_int64(s, 1)),
          seconds: sqlite3_column_double(s, 2), fallbacks: Int(sqlite3_column_int64(s, 3)),
          msSum: Int(sqlite3_column_int64(s, 4)))
      }).first ?? Totals()

    let apps = try query(
      """
      SELECT target_app, COUNT(*), SUM(word_count) FROM dictations
      WHERE timestamp >= ?1 AND target_app IS NOT NULL
      GROUP BY target_app ORDER BY SUM(word_count) DESC, target_app
      """,
      bind: bind,
      row: { s in
        AppUsage(
          bundleID: columnText(s, 0) ?? "", dictations: Int(sqlite3_column_int64(s, 1)),
          words: Int(sqlite3_column_int64(s, 2)))
      })
    let engines = try query(
      """
      SELECT engine_used, COUNT(*) FROM dictations WHERE timestamp >= ?1
      GROUP BY engine_used ORDER BY COUNT(*) DESC, engine_used
      """,
      bind: bind,
      row: { s in EngineShare(engine: columnText(s, 0) ?? "", count: Int(sqlite3_column_int64(s, 1))) })
    let styles = try query(
      """
      SELECT style_applied, COUNT(*) FROM dictations
      WHERE timestamp >= ?1 AND style_applied IS NOT NULL
      GROUP BY style_applied ORDER BY COUNT(*) DESC, style_applied
      """,
      bind: bind,
      row: { s in StyleUsage(style: columnText(s, 0) ?? "", count: Int(sqlite3_column_int64(s, 1))) })

    // p95 by nearest rank: the (ceil(0.95·n))-th smallest.
    var p95 = 0
    if totals.count > 0 {
      let rank = Int((Double(totals.count) * 0.95).rounded(.up))
      let offset = max(0, min(totals.count - 1, rank - 1))
      p95 = try query(
        "SELECT processing_ms FROM dictations WHERE timestamp >= ?1 ORDER BY processing_ms LIMIT 1 OFFSET ?2",
        bind: { s in
          sqlite3_bind_double(s, 1, since)
          sqlite3_bind_int(s, 2, Int32(offset))
        },
        row: { Int(sqlite3_column_int64($0, 0)) }).first ?? 0
    }

    // Daily trend over the whole history, bucketed in Swift by the caller's
    // calendar — only (timestamp, words) pairs from the trend window load.
    let today = calendar.startOfDay(for: now)
    let windowStart = calendar.date(byAdding: .day, value: -(InsightsAggregator.trendDays - 1), to: today) ?? today
    var byDay: [Date: Int] = [:]
    let trendRows = try query(
      "SELECT timestamp, word_count FROM dictations WHERE timestamp >= ?1",
      bind: { sqlite3_bind_double($0, 1, windowStart.timeIntervalSince1970) },
      row: { s in (Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), Int(sqlite3_column_int64(s, 1))) })
    for (timestamp, words) in trendRows {
      byDay[calendar.startOfDay(for: timestamp), default: 0] += words
    }
    let daily: [DailyWords] = (0..<InsightsAggregator.trendDays).reversed().compactMap { offset in
      guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
      return DailyWords(day: day, words: byDay[day] ?? 0)
    }

    let speakingWPM = totals.seconds > 0 ? Double(totals.words) / (totals.seconds / 60) : 0
    let typingSeconds = typingWPM > 0 ? Double(totals.words) / typingWPM * 60 : 0
    return Insights(
      totalWords: totals.words,
      totalDictations: totals.count,
      totalDictationSeconds: totals.seconds,
      speakingWPM: speakingWPM,
      timeSavedSeconds: max(0, typingSeconds - totals.seconds),
      topApps: apps,
      engineSplit: engines,
      fallbackRate: totals.count == 0 ? 0 : Double(totals.fallbacks) / Double(totals.count),
      styleUsage: styles,
      averageProcessingMs: totals.count == 0 ? 0 : totals.msSum / totals.count,
      p95ProcessingMs: p95,
      dailyWords: daily)
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
    let builtin = try query(
      "SELECT COUNT(*) FROM styles WHERE id = ?1 AND builtin = 1",
      bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, sqliteTransient) },
      row: { Int(sqlite3_column_int64($0, 0)) }).first ?? 0
    guard builtin == 0 else { throw FlowStoreError(message: "built-in styles cannot be deleted") }
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
    // Creation attributes only apply to a new directory; a backup restore or
    // a Finder "Get Info" change can loosen an existing one. Best effort: the
    // file's own 0600 below is the hard requirement.
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

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
    for suffix in ["-wal", "-shm"] {
      let sidecar = url.path + suffix
      if fileManager.fileExists(atPath: sidecar) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar)
      }
    }
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
    // v3: learning layer rules (suggested → approved/rejected).
    [
      """
      CREATE TABLE learned_rules (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        pattern TEXT NOT NULL,
        replacement TEXT,
        evidence INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'suggested',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE(kind, pattern)
      )
      """
    ],
    // v4: why an insertion fell back, for the History tooltip.
    [
      "ALTER TABLE dictations ADD COLUMN insertion_diagnostics TEXT"
    ],
    // v5: per-app rules. Deleting a style clears the rules that used it.
    [
      """
      CREATE TABLE app_rules (
        bundle_id TEXT PRIMARY KEY,
        cleanup_enabled INTEGER,
        terminal_period INTEGER,
        polish_style_id TEXT REFERENCES styles(id) ON DELETE SET NULL,
        updated_at REAL NOT NULL
      )
      """
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

  /// Seeds only into an empty table — never re-runs on top of a user's own
  /// arrangement, which would collide hotkey slots.
  private func seedBuiltinStylesIfNeeded() throws {
    let count = try scalarInt("SELECT COUNT(*) FROM styles")
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
      processingMs: Int(sqlite3_column_int(statement, 12)),
      insertionDiagnostics: columnText(statement, 13))
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
