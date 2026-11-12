import Foundation
import Testing

@testable import MynaFlowCore

@Suite("Calendar selection")
struct CalendarSelectionTests {
  @Test("with nothing saved every calendar is watched, including ones added later")
  func defaultsToAll() {
    let selection = CalendarSelection(encoded: nil)
    #expect(selection.includes("work"))
    #expect(selection.includes("a-calendar-added-tomorrow"))
  }

  @Test("turning a calendar off excludes only that calendar")
  func turningOff() {
    let selection = CalendarSelection(encoded: nil).setting("birthdays", watched: false)
    #expect(!selection.includes("birthdays"))
    #expect(selection.includes("work"))
  }

  @Test("turning it back on includes it again")
  func turningBackOn() {
    let selection = CalendarSelection(encoded: nil)
      .setting("birthdays", watched: false)
      .setting("birthdays", watched: true)
    #expect(selection.includes("birthdays"))
  }

  @Test("the selection survives being saved and read back")
  func roundTrip() {
    let saved = CalendarSelection(encoded: nil)
      .setting("birthdays", watched: false)
      .setting("holidays,with,commas", watched: false)
    let read = CalendarSelection(encoded: saved.encoded)
    #expect(read == saved)
    #expect(!read.includes("holidays,with,commas"))
  }

  @Test("an unreadable saved value falls back to watching everything")
  func corruptValue() {
    #expect(CalendarSelection(encoded: "not json").includes("work"))
  }
}
