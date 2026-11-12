import Foundation
import Testing

@testable import MynaFlowCore

@Suite("CalendarMeeting.current — naming notes started by hand")
struct CalendarMeetingCurrentTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func meeting(
    _ title: String, startOffset: TimeInterval, minutes: Double, linked: Bool = false
  ) -> CalendarMeeting {
    let start = now.addingTimeInterval(startOffset)
    return CalendarMeeting(
      id: title, title: title, start: start, end: start.addingTimeInterval(minutes * 60),
      link: linked ? URL(string: "https://zoom.us/j/1") : nil)
  }

  @Test("a meeting that started six minutes ago names the notes")
  func meetingInProgress() {
    let events = [meeting("AdOps Touchbase", startOffset: -6 * 60, minutes: 30)]
    #expect(CalendarMeeting.current(in: events, at: now)?.title == "AdOps Touchbase")
  }

  @Test("a meeting starting within a minute counts as current")
  func aboutToStart() {
    let events = [meeting("Standup", startOffset: 45, minutes: 15)]
    #expect(CalendarMeeting.current(in: events, at: now)?.title == "Standup")
  }

  @Test("a meeting later in the day does not name the notes")
  func laterMeeting() {
    let events = [meeting("Birthdays", startOffset: 54 * 60, minutes: 30)]
    #expect(CalendarMeeting.current(in: events, at: now) == nil)
  }

  @Test("a meeting that already ended does not name the notes")
  func endedMeeting() {
    let events = [meeting("Earlier", startOffset: -45 * 60, minutes: 30)]
    #expect(CalendarMeeting.current(in: events, at: now) == nil)
  }

  @Test("of two overlapping meetings, the one with a video link wins")
  func linkedFirst() {
    let events = [
      meeting("Focus block", startOffset: -10 * 60, minutes: 60),
      meeting("Weekly Sync", startOffset: -5 * 60, minutes: 30, linked: true),
    ]
    #expect(CalendarMeeting.current(in: events, at: now)?.title == "Weekly Sync")
  }
}
