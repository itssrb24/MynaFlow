import Foundation

/// Decides when to ask about meeting notes, from calendar events and which
/// apps hold the mic. Pure and clock-free: every tick passes `now`. It never
/// starts or stops anything itself — it only returns a prompt to show.
///
/// - Calendar: ask once per event, from a minute before its start until five
///   minutes after.
/// - Call: ask once per call when a meeting app or browser has held the mic
///   for `joinGrace`. A hold survives drops shorter than `releaseGrace`.
/// - Recording: no start prompts; once a call that was part of the recording
///   has let go of the mic for `releaseGrace`, ask once whether to stop.
public struct MeetingDetector: Sendable {
  public static let leadTime: TimeInterval = 60
  public static let lateWindow: TimeInterval = 300
  public static let joinGrace: TimeInterval = 5
  public static let releaseGrace: TimeInterval = 10

  private struct Hold {
    var since: Date
    var lastSeen: Date
    var prompted = false
  }

  private var holds: [MicHolder: Hold] = [:]
  private var promptedEvents: Set<String> = []
  private var dismissedEvents: Set<String> = []
  private var openCalendarPrompt = false
  /// Call apps seen during the current recording; nil when not recording.
  private var recordingCalls: Set<MicHolder>?
  private var endPrompted = false

  public init() {}

  public mutating func evaluate(_ input: DetectionInput) -> DetectionPrompt? {
    updateHolds(input)
    if input.isRecording { return whileRecording(input) }
    recordingCalls = nil
    endPrompted = false
    if let prompt = calendarPrompt(input) { return prompt }
    return callPrompt(input)
  }

  public mutating func resolve(_ prompt: DetectionPrompt, outcome: PromptOutcome) {
    switch prompt {
    case .calendarStart(let meeting):
      openCalendarPrompt = false
      if outcome == .dismissed { dismissedEvents.insert(meeting.id) }
    case .callJoined(_, let meeting):
      if outcome == .dismissed, let meeting { dismissedEvents.insert(meeting.id) }
    case .callEnded:
      break
    }
  }

  // MARK: - Steps

  private mutating func updateHolds(_ input: DetectionInput) {
    for holder in input.micHolders {
      holds[holder, default: Hold(since: input.now, lastSeen: input.now)].lastSeen = input.now
    }
    holds = holds.filter { input.now.timeIntervalSince($0.value.lastSeen) <= Self.releaseGrace }
  }

  private mutating func whileRecording(_ input: DetectionInput) -> DetectionPrompt? {
    // A call already covered by a recording never asks to start afterwards,
    // and a meeting that starts mid-recording is part of it.
    for holder in input.micHolders { holds[holder]?.prompted = true }
    for meeting in inWindow(input) { promptedEvents.insert(meeting.id) }
    let calls = (recordingCalls ?? []).union(input.micHolders)
    recordingCalls = calls
    // Ask once, and only when every call app in this recording has let go.
    guard !endPrompted, calls.allSatisfy({ holds[$0] == nil }),
      let ended = calls.sorted(by: Self.order).first
    else { return nil }
    endPrompted = true
    return .callEnded(ended)
  }

  private mutating func calendarPrompt(_ input: DetectionInput) -> DetectionPrompt? {
    let due = inWindow(input)
      .filter { !promptedEvents.contains($0.id) }
      .sorted(by: Self.linkedFirst)
    guard let meeting = due.first else { return nil }
    promptedEvents.insert(meeting.id)
    openCalendarPrompt = true
    return .calendarStart(meeting)
  }

  private mutating func callPrompt(_ input: DetectionInput) -> DetectionPrompt? {
    // Only apps holding the mic right now; a hold kept alive through a short
    // drop must not finish its grace period while the mic is free.
    let ready = holds
      .filter { input.micHolders.contains($0.key) }
      .filter { !$0.value.prompted && input.now.timeIntervalSince($0.value.since) >= Self.joinGrace }
      .map(\.key)
      .sorted(by: Self.order)
    guard let holder = ready.first else { return nil }
    holds[holder]?.prompted = true
    let meeting = ongoing(input).first
    // The open calendar prompt already covers this call, and "Not now" on a
    // meeting covers its call too.
    if openCalendarPrompt { return nil }
    if let meeting, dismissedEvents.contains(meeting.id) { return nil }
    return .callJoined(holder, meeting: meeting)
  }

  // MARK: - Helpers

  /// Events whose start-prompt window contains now.
  private func inWindow(_ input: DetectionInput) -> [CalendarMeeting] {
    input.events.filter {
      let offset = input.now.timeIntervalSince($0.start)
      return offset >= -Self.leadTime && offset <= Self.lateWindow
    }
  }

  /// Events happening now (or about to), linked ones first.
  private func ongoing(_ input: DetectionInput) -> [CalendarMeeting] {
    input.events
      .filter { input.now >= $0.start.addingTimeInterval(-Self.leadTime) && input.now < $0.end }
      .sorted(by: Self.linkedFirst)
  }

  /// Events with a video link first, then the earliest start.
  private static func linkedFirst(_ lhs: CalendarMeeting, _ rhs: CalendarMeeting) -> Bool {
    if (lhs.link != nil) != (rhs.link != nil) { return lhs.link != nil }
    return lhs.start < rhs.start
  }

  /// Meeting apps before browsers, then by name, so ties pick the same app.
  private static func order(_ lhs: MicHolder, _ rhs: MicHolder) -> Bool {
    if lhs.kind != rhs.kind { return lhs.kind == .meetingApp }
    return lhs.name < rhs.name
  }
}
