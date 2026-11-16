import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension FlowStore {
  public func insertMeeting(_ record: MeetingRecord) throws {
    let encoder = JSONEncoder()
    let segments = String(decoding: try encoder.encode(record.segments), as: UTF8.self)
    let keyPoints = try record.summary.map {
      String(decoding: try encoder.encode($0.keyPoints), as: UTF8.self)
    }
    let actionItems = try record.summary.map {
      String(decoding: try encoder.encode($0.actionItems), as: UTF8.self)
    }
    let names = record.speakerNames.isEmpty ? nil : try Self.encodeNames(record.speakerNames)
    let context = try record.context.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    try run(
      """
      INSERT INTO meetings (
        id, started_at, duration_seconds, segments, key_points, action_items, summary_note,
        event_title, speaker_names, context, series_key
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, transient)
        sqlite3_bind_double(statement, 2, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, record.durationSeconds)
        sqlite3_bind_text(statement, 4, segments, -1, transient)
        bindText(statement, 5, keyPoints)
        bindText(statement, 6, actionItems)
        bindText(statement, 7, record.summaryNote)
        bindText(statement, 8, record.eventTitle)
        bindText(statement, 9, names)
        bindText(statement, 10, context)
        bindText(statement, 11, record.context?.seriesKey)
      })
  }

  /// Attaches an invite to a meeting after the fact ("Link to calendar
  /// event…"); its title becomes the meeting's name.
  public func setMeetingContext(_ context: MeetingContext, meetingID: UUID) throws {
    let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    let key = meetingID.uuidString
    try run(
      "UPDATE meetings SET context = ?1, series_key = ?2, event_title = ?3 WHERE id = ?4",
      bind: { statement in
        bindText(statement, 1, json)
        bindText(statement, 2, context.seriesKey)
        bindText(statement, 3, context.title)
        sqlite3_bind_text(statement, 4, key, -1, transient)
      })
  }

  /// Earlier meetings of the same recurring series, newest first.
  public func meetings(inSeries seriesKey: String, before date: Date, limit: Int = 3) throws
    -> [MeetingRecord]
  {
    try query(
      """
      SELECT \(Self.meetingColumns) FROM meetings
      WHERE series_key = ?1 AND started_at < ?2 ORDER BY started_at DESC LIMIT ?3
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, seriesKey, -1, transient)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(limit))
      },
      row: Self.readMeeting)
  }

  private static let meetingColumns = """
    id, started_at, duration_seconds, segments, key_points, action_items, summary_note,
      event_title, speaker_names, context
    """

  /// Names (or, with a blank name, un-names) one speaker in one meeting.
  public func setSpeakerName(_ name: String, speaker: Int, meetingID: UUID) throws {
    let key = meetingID.uuidString
    let stored = try query(
      "SELECT speaker_names FROM meetings WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, key, -1, transient) },
      row: { text($0, 0) }
    ).first ?? nil
    var names = try stored.map(Self.decodeNames) ?? [:]
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    names[speaker] = trimmed.isEmpty ? nil : trimmed
    let json = names.isEmpty ? nil : try Self.encodeNames(names)
    try run(
      "UPDATE meetings SET speaker_names = ?1 WHERE id = ?2",
      bind: { statement in
        bindText(statement, 1, json)
        sqlite3_bind_text(statement, 2, key, -1, transient)
      })
  }

  // JSON object keys are strings; speaker numbers become "1", "2", ….
  private static func encodeNames(_ names: [Int: String]) throws -> String {
    let byKey = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
    return String(decoding: try JSONEncoder().encode(byKey), as: UTF8.self)
  }

  private static func decodeNames(_ json: String) throws -> [Int: String] {
    let byKey = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    return Dictionary(uniqueKeysWithValues: byKey.compactMap { key, value in
      Int(key).map { ($0, value) }
    })
  }

  /// Newest first.
  public func meetings(limit: Int) throws -> [MeetingRecord] {
    try query(
      """
      SELECT \(Self.meetingColumns)
      FROM meetings ORDER BY started_at DESC LIMIT ?1
      """,
      bind: { sqlite3_bind_int($0, 1, Int32(limit)) },
      row: Self.readMeeting)
  }

  public func deleteMeeting(id: UUID) throws {
    let key = id.uuidString
    try run(
      "DELETE FROM meetings WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, key, -1, transient) })
  }

  private static func readMeeting(_ statement: OpaquePointer) throws -> MeetingRecord {
    let decoder = JSONDecoder()
    guard let idText = text(statement, 0), let id = UUID(uuidString: idText),
      let segmentsJSON = text(statement, 3)
    else { throw FlowStoreError(message: "malformed meeting row") }
    let segments = try decoder.decode([MeetingSegment].self, from: Data(segmentsJSON.utf8))
    let summary: MeetingSummary? =
      if let points = text(statement, 4), let actions = text(statement, 5) {
        MeetingSummary(
          keyPoints: try decoder.decode([String].self, from: Data(points.utf8)),
          actionItems: try decoder.decode([String].self, from: Data(actions.utf8)))
      } else {
        nil
      }
    return MeetingRecord(
      id: id,
      startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      durationSeconds: sqlite3_column_double(statement, 2),
      segments: segments,
      summary: summary,
      summaryNote: text(statement, 6),
      eventTitle: text(statement, 7),
      speakerNames: try text(statement, 8).map(decodeNames) ?? [:],
      context: try text(statement, 9).map {
        try decoder.decode(MeetingContext.self, from: Data($0.utf8))
      })
  }
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
  guard sqlite3_column_type(statement, index) != SQLITE_NULL,
    let cString = sqlite3_column_text(statement, index)
  else { return nil }
  return String(cString: cString)
}

private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
  if let value {
    sqlite3_bind_text(statement, index, value, -1, transient)
  } else {
    sqlite3_bind_null(statement, index)
  }
}
