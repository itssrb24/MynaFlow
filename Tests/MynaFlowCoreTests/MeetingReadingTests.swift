import Foundation
import Testing

@testable import MynaFlowCore

@Suite("MeetingTranscript.turns — chunks read as speaker turns")
struct MeetingTurnsTests {
  @Test("consecutive chunks from one speaker join into one turn")
  func sameSpeakerJoins() {
    let turns = MeetingTranscript.turns([
      MeetingSegment(channel: .others, startSeconds: 0, text: "Let's get started."),
      MeetingSegment(channel: .others, startSeconds: 30, text: "  First, the launch date. "),
    ])
    #expect(turns.count == 1)
    #expect(turns.first?.text == "Let's get started. First, the launch date.")
    #expect(turns.first?.startSeconds == 0)
  }

  @Test("a speaker change starts a new turn, in time order")
  func speakerChangeSplits() {
    let turns = MeetingTranscript.turns([
      MeetingSegment(channel: .others, startSeconds: 30, text: "Any updates?"),
      MeetingSegment(channel: .others, startSeconds: 0, text: "Hello everyone."),
      MeetingSegment(channel: .you, startSeconds: 31, text: "Yes, one."),
      MeetingSegment(channel: .others, startSeconds: 60, text: "Go ahead."),
    ])
    #expect(turns.map(\.channel) == [.others, .you, .others])
    #expect(turns.map(\.startSeconds) == [0, 31, 60])
    #expect(turns.first?.text == "Hello everyone. Any updates?")
  }

  @Test("blank chunks are dropped and never split a turn")
  func blanksDropped() {
    let turns = MeetingTranscript.turns([
      MeetingSegment(channel: .others, startSeconds: 0, text: "One."),
      MeetingSegment(channel: .you, startSeconds: 10, text: "   "),
      MeetingSegment(channel: .others, startSeconds: 30, text: "Two."),
    ])
    #expect(turns.count == 1)
    #expect(turns.first?.text == "One. Two.")
  }

  @Test("no segments, no turns")
  func empty() {
    #expect(MeetingTranscript.turns([]).isEmpty)
  }
}

@Suite("MeetingSearch.matches — what to highlight in a transcript")
struct MeetingMatchesTests {
  @Test("finds every occurrence, ignoring case")
  func everyOccurrence() {
    let text = "Trial ends soon. The free trial is the TRIAL."
    #expect(MeetingSearch.matches(of: "trial", in: text).count == 3)
  }

  @Test("ignores accents both ways")
  func diacritics() {
    #expect(MeetingSearch.matches(of: "cafe", in: "Meet at the café.").count == 1)
    #expect(MeetingSearch.matches(of: "café", in: "Meet at the cafe.").count == 1)
  }

  @Test("ranges point at the matched text")
  func rangesAreExact() {
    let text = "Follow up with Maurice"
    let ranges = MeetingSearch.matches(of: "maurice", in: text)
    #expect(ranges.map { String(text[$0]) } == ["Maurice"])
  }

  @Test("an empty or blank query matches nothing")
  func emptyQuery() {
    #expect(MeetingSearch.matches(of: "", in: "anything").isEmpty)
    #expect(MeetingSearch.matches(of: "   ", in: "anything").isEmpty)
  }
}
