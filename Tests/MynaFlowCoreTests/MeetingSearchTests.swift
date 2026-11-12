import Foundation
import Testing

@testable import MynaFlowCore

private func meeting(
  title: String? = nil, keyPoints: [String] = [], actionItems: [String] = [],
  said: String = "Shall we ship it?"
) -> MeetingRecord {
  MeetingRecord(
    startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 60,
    segments: [MeetingSegment(channel: .others, startSeconds: 0, text: said)],
    summary: keyPoints.isEmpty && actionItems.isEmpty
      ? nil : MeetingSummary(keyPoints: keyPoints, actionItems: actionItems),
    summaryNote: nil, eventTitle: title)
}

@Suite("Meeting search")
struct MeetingSearchTests {
  @Test("an empty or blank query keeps every meeting")
  func emptyQuery() {
    let all = [meeting(), meeting(title: "Standup")]
    #expect(MeetingSearch.filter(all, query: "") == all)
    #expect(MeetingSearch.filter(all, query: "   ") == all)
  }

  @Test("matches the calendar event title")
  func matchesTitle() {
    let standup = meeting(title: "Weekly Standup")
    #expect(MeetingSearch.filter([meeting(), standup], query: "standup") == [standup])
  }

  @Test("matches key points and action items")
  func matchesSummary() {
    let launch = meeting(keyPoints: ["Launch moves to March"])
    let task = meeting(actionItems: ["Priya: billing migration"])
    let all = [meeting(), launch, task]
    #expect(MeetingSearch.filter(all, query: "march") == [launch])
    #expect(MeetingSearch.filter(all, query: "Billing") == [task])
  }

  @Test("matches what was said in the transcript")
  func matchesTranscript() {
    let hiring = meeting(said: "We agreed to hire one more designer.")
    #expect(MeetingSearch.filter([meeting(), hiring], query: "designer") == [hiring])
  }

  @Test("ignores accents and case")
  func diacriticInsensitive() {
    let cafe = meeting(title: "Café planning")
    #expect(MeetingSearch.filter([cafe], query: "CAFE") == [cafe])
  }

  @Test("every word must appear somewhere in the meeting")
  func allWords() {
    let both = meeting(title: "Budget review", said: "Approved for March.")
    let one = meeting(title: "Budget review", said: "Nothing decided.")
    #expect(MeetingSearch.filter([both, one], query: "budget march") == [both])
  }
}
