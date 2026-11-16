import Foundation
import Testing

@testable import MynaFlowCore

@Suite("MeetingSeries — grouping occurrences of a recurring meeting")
struct MeetingSeriesTests {
  @Test("occurrences of one event share a key; the occurrence suffix is dropped")
  func eventIDWins() {
    #expect(MeetingSeries.key(eventID: "ABC123/RID=1700000000", title: "Weekly") == "event:ABC123")
    #expect(MeetingSeries.key(eventID: "ABC123", title: "Something else") == "event:ABC123")
  }

  @Test("without an event ID, numbered titles still group")
  func titleFallback() {
    #expect(
      MeetingSeries.key(eventID: nil, title: "Weekly Standup 3/12")
        == MeetingSeries.key(eventID: "", title: "weekly standup"))
  }

  @Test("a meeting with no event and no title has no series")
  func noSeries() {
    #expect(MeetingSeries.key(eventID: nil, title: "") == nil)
  }
}

@Suite("InviteAgenda — the human part of an invite's notes")
struct InviteAgendaTests {
  @Test("conference boilerplate and links are removed, the agenda is kept")
  func stripsBoilerplate() {
    let notes = """
      Agenda:
      1. Launch timeline
      2. Free trial terms

      ──────────
      Join Zoom Meeting
      https://zoom.us/j/123456789?pwd=abc
      Meeting ID: 123 456 789
      Passcode: 42
      Dial by your location
      +1 646 558 8656 US (New York)
      """
    #expect(InviteAgenda.clean(notes) == "Agenda:\n1. Launch timeline\n2. Free trial terms")
  }

  @Test("Teams and Meet footers go too")
  func otherProviders() {
    let notes = """
      Quick sync on budget.
      ________________________________________________________________________________
      Microsoft Teams meeting
      Join on your computer, mobile app or room device
      Click here to join the meeting
      Meeting ID: 222 333 444 555
      Join with Google Meet: https://meet.google.com/abc-defg-hij
      """
    #expect(InviteAgenda.clean(notes) == "Quick sync on budget.")
  }

  @Test("empty or boilerplate-only notes give no agenda; long notes are capped")
  func emptyAndCap() {
    #expect(InviteAgenda.clean(nil) == nil)
    #expect(InviteAgenda.clean("Join Zoom Meeting\nhttps://zoom.us/j/1") == nil)
    let long = String(repeating: "word ", count: 1_000)
    #expect((InviteAgenda.clean(long)?.count ?? 0) <= InviteAgenda.maxCharacters)
  }
}

@Suite("MeetingAttendee — people on the invite, not rooms or lists")
struct MeetingAttendeeTests {
  @Test("rooms, resources and no-reply addresses are not people")
  func nonHuman() {
    #expect(!MeetingAttendee.isPerson(name: "NYC-12-Boardroom (10)", email: "nyc.boardroom@resource.calendar.google.com"))
    #expect(!MeetingAttendee.isPerson(name: "Team", email: "noreply@company.com"))
    #expect(MeetingAttendee.isPerson(name: "Maurice Lee", email: "maurice@company.com"))
  }

  @Test("a display name falls back to the email's local part, tidied")
  func displayName() {
    #expect(MeetingAttendee(name: nil, email: "maurice.lee@company.com").displayName == "Maurice Lee")
    #expect(MeetingAttendee(name: "Dan Smith", email: "dan@x.com").displayName == "Dan Smith")
  }
}

@Suite("MeetingContext — what a recording knows about its meeting")
struct MeetingContextTests {
  @Test("a calendar meeting becomes a context with series, people and agenda")
  func fromCalendar() {
    let meeting = CalendarMeeting(
      id: "E1@1", title: "Launch sync", start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 1800), link: nil, eventID: "E1",
      attendees: [
        MeetingAttendee(name: "Me", email: "me@x.com", isSelf: true),
        MeetingAttendee(name: "Maurice Lee", email: "maurice@x.com"),
      ],
      organizer: "Maurice Lee", agenda: "Budget")
    let context = MeetingContext(meeting)
    #expect(context.title == "Launch sync")
    #expect(context.seriesKey == "event:E1")
    #expect(context.attendees.count == 2)
    #expect(context.others.map(\.displayName) == ["Maurice Lee"])
    #expect(context.agenda == "Budget")
  }
}
