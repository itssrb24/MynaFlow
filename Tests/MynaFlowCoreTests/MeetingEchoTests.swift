import Foundation
import Testing

@testable import MynaFlowCore

@Suite("MeetingEcho — the call heard back through the mic is not \"You\"")
struct MeetingEchoTests {
  func you(_ at: Double, _ text: String) -> MeetingSegment {
    MeetingSegment(channel: .you, startSeconds: at, text: text)
  }

  func others(_ at: Double, _ text: String) -> MeetingSegment {
    MeetingSegment(channel: .others, startSeconds: at, text: text)
  }

  @Test("a mic line that repeats the call at the same moment is dropped")
  func echoDropped() {
    let segments = [
      you(0, "I think we've got."),
      others(0, "I think we've got a good going. Let's go ahead and get started."),
    ]
    #expect(MeetingEcho.removeEchoes(segments, window: 30).map(\.channel) == [.others])
  }

  @Test("punctuation and case differences don't hide an echo")
  func normalizes() {
    let segments = [
      you(30, "launch date, however if you subtract"),
      others(30, "Our LAUNCH DATE however, if you subtract all the holidays"),
    ]
    #expect(MeetingEcho.removeEchoes(segments, window: 30).isEmpty == false)
    #expect(MeetingEcho.removeEchoes(segments, window: 30).allSatisfy { $0.channel == .others })
  }

  @Test("an echo spanning two of the call's chunks is still dropped")
  func spansChunks() {
    let segments = [
      you(29, "let's go ahead and get started okay hello everyone"),
      others(0, "Thanks for joining, let's go ahead and get started"),
      others(30, "okay hello everyone today is Thursday"),
    ]
    #expect(MeetingEcho.removeEchoes(segments, window: 30).allSatisfy { $0.channel == .others })
  }

  @Test("the same words much later are a real line, not an echo")
  func outsideWindowKept() {
    let segments = [
      others(0, "I think we've got a good going"),
      you(300, "I think we've got a good going"),
    ]
    #expect(MeetingEcho.removeEchoes(segments, window: 30).count == 2)
  }

  @Test("a real reply that shares a few words with the call is kept")
  func realReplyKept() {
    let segments = [
      others(0, "I think we've got a good going on the free trial"),
      you(5, "Yes, I think we should drop the free trial for now"),
    ]
    #expect(MeetingEcho.removeEchoes(segments, window: 30).count == 2)
  }

  @Test("very short lines are kept; two words are too little to call an echo")
  func shortKept() {
    let segments = [others(0, "Sounds good to me"), you(1, "Sounds good")]
    #expect(MeetingEcho.removeEchoes(segments, window: 30).count == 2)
  }

  @Test("the call's own lines are never removed, and order is kept")
  func othersUntouched() {
    let segments = [
      others(0, "First point"),
      you(0, "First point about the budget numbers"),
      others(30, "First point about the budget numbers"),
    ]
    let kept = MeetingEcho.removeEchoes(segments, window: 30)
    #expect(kept.map(\.startSeconds) == [0, 30])
    #expect(kept.allSatisfy { $0.channel == .others })
  }
}
