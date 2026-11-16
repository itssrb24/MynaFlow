import Foundation
import Testing

@testable import MynaFlowCore

private func databaseURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("people-tests-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("flow.sqlite", isDirectory: false)
}

private func meeting(
  at seconds: Double = 1_800_000_000, attendees: [MeetingAttendee] = [],
  segments: [MeetingSegment] = [], names: [Int: String] = [:], series: String? = nil
) -> MeetingRecord {
  MeetingRecord(
    startedAt: Date(timeIntervalSince1970: seconds), durationSeconds: 60, segments: segments,
    summary: MeetingSummary(overview: "x", keyPoints: [], actionItems: []), summaryNote: nil,
    speakerNames: names,
    context: MeetingContext(title: "Sync", seriesKey: series, attendees: attendees)
  ).withSummaryBasis()
}

@Suite("People from invites")
struct MeetingPeopleStoreTests {
  @Test("attendees become people when a meeting is saved, one per email")
  func attendeesBecomePeople() async throws {
    let store = try await FlowStore.open(at: databaseURL())
    let me = MeetingAttendee(name: "Me", email: "me@x.com", isSelf: true)
    let maurice = MeetingAttendee(name: "Maurice Lee", email: "Maurice@X.com")
    try await store.insertMeeting(meeting(attendees: [me, maurice]))
    try await store.insertMeeting(
      meeting(at: 1_800_000_100, attendees: [MeetingAttendee(name: nil, email: "maurice@x.com")]))
    let people = try await store.people()
    #expect(people.map(\.name) == ["Maurice Lee"])
    #expect(people.first?.email == "maurice@x.com")
    await store.close()
  }

  @Test("naming a speaker links the person and teaches the name to the vocabulary")
  func nameSpeaker() async throws {
    let store = try await FlowStore.open(at: databaseURL())
    let record = meeting(
      attendees: [MeetingAttendee(name: "Maurice Lee", email: "maurice@x.com")],
      segments: [MeetingSegment(channel: .others, startSeconds: 0, text: "Hi.", speaker: 1)])
    try await store.insertMeeting(record)
    let maurice = try #require(try await store.people().first)
    try await store.setSpeaker(1, to: maurice, meetingID: record.id)

    let loaded = try #require(try await store.meetings(limit: 1).first)
    #expect(loaded.speakerNames == [1: "Maurice Lee"])
    #expect(loaded.speakerPeople == [1: maurice.id])
    #expect(loaded.isSummaryStale)
    #expect(try await store.vocabularyTerms().map(\.term).contains("Maurice Lee"))
    await store.close()
  }

  @Test("a typed name becomes a person once; clearing a name drops the link")
  func typedNames() async throws {
    let store = try await FlowStore.open(at: databaseURL())
    let record = meeting(segments: [MeetingSegment(channel: .others, startSeconds: 0, text: "Hi.", speaker: 1)])
    try await store.insertMeeting(record)
    let first = try await store.person(named: "Priya Shah")
    let again = try await store.person(named: " priya shah ")
    #expect(first.id == again.id)
    try await store.setSpeaker(1, to: first, meetingID: record.id)
    try await store.setSpeakerName("", speaker: 1, meetingID: record.id)
    let loaded = try #require(try await store.meetings(limit: 1).first)
    #expect(loaded.speakerNames.isEmpty)
    #expect(loaded.speakerPeople.isEmpty)
    await store.close()
  }

  @Test("'same person' moves one speaker's lines to another and drops the old name")
  func merge() async throws {
    let store = try await FlowStore.open(at: databaseURL())
    let record = meeting(
      segments: [
        MeetingSegment(channel: .others, startSeconds: 0, text: "One.", speaker: 1),
        MeetingSegment(channel: .others, startSeconds: 5, text: "Two.", speaker: 2),
        MeetingSegment(channel: .you, startSeconds: 7, text: "Mine."),
      ], names: [2: "Dan"])
    try await store.insertMeeting(record)
    try await store.mergeSpeaker(2, into: 1, meetingID: record.id)

    let loaded = try #require(try await store.meetings(limit: 1).first)
    #expect(loaded.segments.map(\.speaker) == [1, 1, nil])
    #expect(loaded.speakerNames[2] == nil)
    await store.close()
  }
}

@Suite("SpeakerSuggestions — who a speaker probably is")
struct SpeakerSuggestionsTests {
  @Test("unnamed attendees first, then names from the last meeting in the series, no repeats")
  func order() {
    let current = meeting(
      attendees: [
        MeetingAttendee(name: "Me", email: "me@x.com", isSelf: true),
        MeetingAttendee(name: "Maurice Lee", email: "m@x.com"),
        MeetingAttendee(name: "Dan Smith", email: "d@x.com"),
      ], names: [2: "Dan Smith"])
    let last = meeting(at: 1_700_000_000, names: [1: "Maurice Lee", 3: "Priya Shah"])
    #expect(SpeakerSuggestions.names(for: current, previous: last) == ["Maurice Lee", "Priya Shah"])
  }

  @Test("with no invite and no series, there is nothing to suggest")
  func none() {
    let bare = MeetingRecord(
      startedAt: Date(), durationSeconds: 1, segments: [], summary: nil, summaryNote: nil)
    #expect(SpeakerSuggestions.names(for: bare, previous: nil).isEmpty)
  }
}
