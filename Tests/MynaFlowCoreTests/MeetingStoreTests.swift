import Foundation
import Testing

@testable import MynaFlowCore

private func temporaryDatabaseURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("meeting-store-tests-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("flow.sqlite", isDirectory: false)
}

private func makeMeeting(
  startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
  summary: MeetingSummary? = MeetingSummary(keyPoints: ["Ship it"], actionItems: ["Sam: tag"]),
  note: String? = nil
) -> MeetingRecord {
  MeetingRecord(
    startedAt: startedAt,
    durationSeconds: 65,
    segments: [
      MeetingSegment(channel: .you, startSeconds: 0, text: "Shall we ship?"),
      MeetingSegment(channel: .others, startSeconds: 30, text: "Yes, ship it."),
    ],
    summary: summary,
    summaryNote: note)
}

@Suite("Meeting persistence")
struct MeetingStoreTests {
  @Test("a meeting round-trips with transcript and summary")
  func roundTrip() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    let meeting = makeMeeting()
    try await store.insertMeeting(meeting)
    #expect(try await store.meetings(limit: 10) == [meeting])
    await store.close()
  }

  @Test("a meeting keeps the calendar event title it was started for")
  func eventTitleRoundTrip() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    let base = makeMeeting()
    let meeting = MeetingRecord(
      id: base.id, startedAt: base.startedAt, durationSeconds: base.durationSeconds,
      segments: base.segments, summary: base.summary, summaryNote: nil,
      eventTitle: "Weekly sync")
    try await store.insertMeeting(meeting)
    let read = try await store.meetings(limit: 10)
    #expect(read == [meeting])
    #expect(read.first?.title.hasPrefix("Weekly sync — ") == true)
    #expect(makeMeeting().title.hasPrefix("Meeting — "))
    await store.close()
  }

  @Test("a meeting without a summary keeps its note")
  func noSummary() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    let meeting = makeMeeting(summary: nil, note: MeetingSummarizer.noModelNote)
    try await store.insertMeeting(meeting)
    let fetched = try #require(try await store.meetings(limit: 10).first)
    #expect(fetched.summary == nil)
    #expect(fetched.summaryNote == MeetingSummarizer.noModelNote)
    await store.close()
  }

  @Test("meetings list newest first and delete removes one")
  func orderingAndDelete() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    let older = makeMeeting(startedAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeMeeting(startedAt: Date(timeIntervalSince1970: 2_000))
    try await store.insertMeeting(older)
    try await store.insertMeeting(newer)
    #expect(try await store.meetings(limit: 10).map(\.id) == [newer.id, older.id])
    try await store.deleteMeeting(id: newer.id)
    #expect(try await store.meetings(limit: 10).map(\.id) == [older.id])
    await store.close()
  }

  @Test("markdown export carries summary, action items and labelled transcript")
  func markdownExport() {
    let markdown = MeetingExporter.markdown(makeMeeting())
    #expect(markdown.contains("## Key points\n- Ship it"))
    #expect(markdown.contains("## Action items\n- [ ] Sam: tag"))
    #expect(markdown.contains("[00:30] Others: Yes, ship it."))
  }

  @Test("markdown export of a summary-less meeting states why")
  func markdownExportWithoutSummary() {
    let markdown = MeetingExporter.markdown(
      makeMeeting(summary: nil, note: MeetingSummarizer.noModelNote))
    #expect(markdown.contains(MeetingSummarizer.noModelNote))
    #expect(!markdown.contains("## Key points"))
  }
}
