import Foundation
import Testing

@testable import MynaFlowCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let zoom = MicHolder(bundleID: "us.zoom.xos", name: "Zoom", kind: .meetingApp)
private let chrome = MicHolder(bundleID: "com.google.Chrome", name: "Chrome", kind: .browser)

private func event(
  _ id: String = "e1", startsAt offset: TimeInterval = 0, minutes: Double = 30,
  link: URL? = URL(string: "https://meet.google.com/x")
) -> CalendarMeeting {
  CalendarMeeting(
    id: id, title: "Weekly sync", start: t0.addingTimeInterval(offset),
    end: t0.addingTimeInterval(offset + minutes * 60), link: link)
}

private func input(
  at seconds: TimeInterval, events: [CalendarMeeting] = [], mic: Set<MicHolder> = [],
  playing: Set<MicHolder> = [], recording: Bool = false
) -> DetectionInput {
  DetectionInput(
    now: t0.addingTimeInterval(seconds), events: events, micHolders: mic,
    callAudioHolders: playing, isRecording: recording)
}

/// Feeds a tick every `step` seconds over `range`, returning every prompt.
private func run(
  _ detector: inout MeetingDetector, _ range: StrideThrough<TimeInterval>,
  events: [CalendarMeeting] = [], mic: Set<MicHolder> = [], playing: Set<MicHolder> = [],
  recording: Bool = false
) -> [DetectionPrompt] {
  range.compactMap {
    detector.evaluate(
      input(at: $0, events: events, mic: mic, playing: playing, recording: recording))
  }
}

@Suite("MeetingDetector")
struct MeetingDetectorTests {
  // MARK: Calendar

  @Test("prompts once when a calendar meeting is about to start")
  func calendarStartOnce() {
    var detector = MeetingDetector()
    let meeting = event()
    #expect(detector.evaluate(input(at: -61, events: [meeting])) == nil)
    let prompt = detector.evaluate(input(at: -60, events: [meeting]))
    #expect(prompt == .calendarStart(meeting))
    detector.resolve(prompt!, outcome: .expired)
    #expect(run(&detector, stride(from: -58, through: 600, by: 2), events: [meeting]).isEmpty)
  }

  @Test("a meeting already well under way does not prompt")
  func tooLate() {
    var detector = MeetingDetector()
    #expect(detector.evaluate(input(at: 301, events: [event()])) == nil)
  }

  @Test("of two meetings starting together, the one with a video link comes first")
  func linkedEventFirst() {
    var detector = MeetingDetector()
    let plain = event("plain", link: nil)
    let linked = event("linked")
    #expect(detector.evaluate(input(at: 0, events: [plain, linked])) == .calendarStart(linked))
  }

  // MARK: Calls

  @Test("a meeting app holding the mic for 5 s prompts once for that call")
  func callJoinedAfterGrace() {
    var detector = MeetingDetector()
    #expect(run(&detector, stride(from: 0, through: 4, by: 2), mic: [zoom]).isEmpty)
    let prompt = detector.evaluate(input(at: 5, mic: [zoom]))
    #expect(prompt == .callJoined(zoom, meeting: nil))
    detector.resolve(prompt!, outcome: .dismissed)
    #expect(run(&detector, stride(from: 6, through: 600, by: 2), mic: [zoom]).isEmpty)
  }

  @Test("a short mic use under the grace period never prompts")
  func shortUseIgnored() {
    var detector = MeetingDetector()
    #expect(run(&detector, stride(from: 0, through: 4, by: 2), mic: [chrome]).isEmpty)
    #expect(run(&detector, stride(from: 6, through: 60, by: 2)).isEmpty)
  }

  @Test("a browser using the mic counts as joining a call")
  func browserCounts() {
    var detector = MeetingDetector()
    let prompts = run(&detector, stride(from: 0, through: 6, by: 1), mic: [chrome])
    #expect(prompts == [.callJoined(chrome, meeting: nil)])
  }

  @Test("a brief mic drop does not make the same call prompt twice")
  func flickerIsOneCall() {
    var detector = MeetingDetector()
    let first = run(&detector, stride(from: 0, through: 6, by: 1), mic: [zoom])
    detector.resolve(first[0], outcome: .expired)
    _ = run(&detector, stride(from: 7, through: 12, by: 1))  // 6 s gap
    #expect(run(&detector, stride(from: 13, through: 40, by: 1), mic: [zoom]).isEmpty)
  }

  @Test("a new call after the last one ended prompts again")
  func newCallPromptsAgain() {
    var detector = MeetingDetector()
    let first = run(&detector, stride(from: 0, through: 6, by: 1), mic: [zoom])
    detector.resolve(first[0], outcome: .dismissed)
    _ = run(&detector, stride(from: 7, through: 30, by: 1))  // ended for 24 s
    let second = run(&detector, stride(from: 31, through: 40, by: 1), mic: [zoom])
    #expect(second == [.callJoined(zoom, meeting: nil)])
  }

  @Test("a call names the calendar meeting it overlaps")
  func callNamesMeeting() {
    var detector = MeetingDetector()
    let meeting = event(startsAt: -600)  // started 10 min ago, still on
    let prompts = run(&detector, stride(from: 0, through: 6, by: 1), events: [meeting], mic: [zoom])
    #expect(prompts == [.callJoined(zoom, meeting: meeting)])
  }

  @Test("two apps joining together give one prompt, not one after the other")
  func simultaneousHoldersPromptOnce() {
    var detector = MeetingDetector()
    let prompts = run(&detector, stride(from: 0, through: 30, by: 1), mic: [zoom, chrome])
    #expect(prompts == [.callJoined(zoom, meeting: nil)])
  }

  // MARK: Dedupe between calendar and call

  @Test("joining the call while the calendar prompt is open does not prompt again")
  func callDuringOpenCalendarPrompt() {
    var detector = MeetingDetector()
    let meeting = event()
    #expect(detector.evaluate(input(at: -60, events: [meeting])) == .calendarStart(meeting))
    let later = run(&detector, stride(from: -59, through: 0, by: 1), events: [meeting], mic: [zoom])
    #expect(later.isEmpty)
  }

  @Test("after 'Not now' on a meeting, joining its call stays quiet")
  func dismissedMeetingSuppressesCall() {
    var detector = MeetingDetector()
    let meeting = event()
    let prompt = detector.evaluate(input(at: -60, events: [meeting]))!
    detector.resolve(prompt, outcome: .dismissed)
    #expect(run(&detector, stride(from: 0, through: 20, by: 1), events: [meeting], mic: [zoom]).isEmpty)
  }

  @Test("if the calendar prompt expired unseen, joining the call still prompts")
  func expiredCalendarPromptAllowsCall() {
    var detector = MeetingDetector()
    let meeting = event()
    let prompt = detector.evaluate(input(at: -60, events: [meeting]))!
    detector.resolve(prompt, outcome: .expired)
    let later = run(&detector, stride(from: 0, through: 6, by: 1), events: [meeting], mic: [zoom])
    #expect(later == [.callJoined(zoom, meeting: meeting)])
  }

  @Test("a call joined under an open calendar prompt still asks once that prompt expires")
  func callAsksAfterCalendarPromptExpires() {
    var detector = MeetingDetector()
    let meeting = event(startsAt: 60, link: nil)
    let calendar = detector.evaluate(input(at: 0, events: [meeting]))!
    #expect(run(&detector, stride(from: 1, through: 20, by: 1), events: [meeting], mic: [zoom]).isEmpty)
    detector.resolve(calendar, outcome: .expired)
    let later = run(&detector, stride(from: 21, through: 24, by: 1), events: [meeting], mic: [zoom])
    #expect(later == [.callJoined(zoom, meeting: meeting)])
  }

  // MARK: While recording

  @Test("nothing prompts to start while notes are recording")
  func noStartPromptsWhileRecording() {
    var detector = MeetingDetector()
    let prompts = run(
      &detector, stride(from: -60, through: 30, by: 1), events: [event()], mic: [zoom],
      recording: true)
    #expect(prompts.isEmpty)
  }

  @Test("call ended prompts once, 10 s after the call app lets go of the mic")
  func callEndedOnce() {
    var detector = MeetingDetector()
    _ = run(&detector, stride(from: 0, through: 20, by: 1), mic: [zoom], recording: true)
    #expect(run(&detector, stride(from: 21, through: 30, by: 1), recording: true).isEmpty)
    let ended = run(&detector, stride(from: 31, through: 120, by: 1), recording: true)
    #expect(ended == [.callEnded(zoom)])
  }

  @Test("a muted call (mic released, still playing the others) is not an ended call")
  func mutedCallIsLive() {
    var detector = MeetingDetector()
    _ = run(&detector, stride(from: 0, through: 20, by: 1), mic: [zoom], playing: [zoom], recording: true)
    let muted = run(&detector, stride(from: 21, through: 150, by: 1), playing: [zoom], recording: true)
    #expect(muted.isEmpty)
    #expect(detector.recordedCallIsLive)
    let hungUp = run(&detector, stride(from: 151, through: 170, by: 1), recording: true)
    #expect(hungUp == [.callEnded(zoom)])
  }

  @Test("a call joined after recording started is watched once it has run for a minute")
  func callJoinedDuringRecording() {
    var detector = MeetingDetector()
    _ = run(&detector, stride(from: 0, through: 5, by: 1), recording: true)
    _ = run(&detector, stride(from: 6, through: 80, by: 1), mic: [chrome], recording: true)
    let ended = run(&detector, stride(from: 81, through: 100, by: 1), recording: true)
    #expect(ended == [.callEnded(chrome)])
  }

  @Test("brief mic use mid-recording (web voice typing) never asks to stop")
  func briefUseDuringRecordingIgnored() {
    var detector = MeetingDetector()
    _ = run(&detector, stride(from: 0, through: 5, by: 1), recording: true)
    _ = run(&detector, stride(from: 6, through: 30, by: 1), mic: [chrome], recording: true)
    #expect(run(&detector, stride(from: 31, through: 200, by: 1), recording: true).isEmpty)
  }

  @Test("a call that comes back withdraws the stop prompt and re-arms it for the real end")
  func resumedCallRearms() {
    var detector = MeetingDetector()
    _ = run(&detector, stride(from: 0, through: 20, by: 1), mic: [zoom], recording: true)
    let first = run(&detector, stride(from: 21, through: 35, by: 1), recording: true)
    #expect(first == [.callEnded(zoom)])
    #expect(!detector.recordedCallIsLive)
    _ = detector.evaluate(input(at: 36, mic: [zoom], recording: true))
    #expect(detector.recordedCallIsLive)
    _ = run(&detector, stride(from: 37, through: 60, by: 1), mic: [zoom], recording: true)
    let second = run(&detector, stride(from: 61, through: 80, by: 1), recording: true)
    #expect(second == [.callEnded(zoom)])
  }

  @Test("recording with no call never prompts that a call ended")
  func noCallNoEnd() {
    var detector = MeetingDetector()
    #expect(run(&detector, stride(from: 0, through: 120, by: 1), recording: true).isEmpty)
  }

  @Test("after recording stops, the same ongoing call does not prompt to start")
  func noRepromptAfterRecordingStops() {
    var detector = MeetingDetector()
    _ = run(&detector, stride(from: 0, through: 20, by: 1), mic: [zoom], recording: true)
    #expect(run(&detector, stride(from: 21, through: 60, by: 1), mic: [zoom]).isEmpty)
  }

  @Test("meetings from more than a day ago are forgotten")
  func forgetsOldEvents() {
    var detector = MeetingDetector()
    let meeting = event()
    let prompt = detector.evaluate(input(at: -60, events: [meeting]))!
    detector.resolve(prompt, outcome: .dismissed)
    #expect(detector.trackedEventCount == 2)
    _ = detector.evaluate(input(at: 25 * 60 * 60))
    #expect(detector.trackedEventCount == 0)
  }
}
