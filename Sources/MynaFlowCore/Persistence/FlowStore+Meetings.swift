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
    try run(
      """
      INSERT INTO meetings (
        id, started_at, duration_seconds, segments, key_points, action_items, summary_note,
        event_title
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
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
      })
  }

  /// Newest first.
  public func meetings(limit: Int) throws -> [MeetingRecord] {
    try query(
      """
      SELECT id, started_at, duration_seconds, segments, key_points, action_items, summary_note,
        event_title
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
      eventTitle: text(statement, 7))
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
