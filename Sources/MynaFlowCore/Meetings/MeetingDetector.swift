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
  /// An app that starts using the mic mid-recording joins the recorded call
  /// only after this long, so web voice typing never arms a stop prompt.
  public static let midRecordingCallGrace: TimeInterval = 60

  private struct Hold {
    var since: Date
    var lastSeen: Date
    var prompted = false
  }

  private var holds: [MicHolder: Hold] = [:]
  /// Event id → start, so entries can be forgotten a day after the event.
  private var promptedEvents: [String: Date] = [:]
  private var dismissedEvents: [String: Date] = [:]
  private static let memory: TimeInterval = 24 * 60 * 60

  /// Remembered event ids — for tests that check old ones are dropped.
  var trackedEventCount: Int { promptedEvents.count + dismissedEvents.count }
  private var openCalendarPrompt = false
  /// Call apps seen during the current recording; nil when not recording.
  private var recordingCalls: Set<MicHolder>?
  private var endPrompted = false

  /// Whether a call that is part of the current recording still holds the
  /// mic. The controller withdraws a showing stop prompt when this turns
  /// back on (the user rejoined after a drop).
  public private(set) var recordedCallIsLive = false

  public init() {}

  public mutating func evaluate(_ input: DetectionInput) -> DetectionPrompt? {
    updateHolds(input)
    forgetOldEvents(input.now)
    if input.isRecording { return whileRecording(input) }
    recordingCalls = nil
    endPrompted = false
    recordedCallIsLive = false
    if let prompt = calendarPrompt(input) { return prompt }
    return callPrompt(input)
  }

  public mutating func resolve(_ prompt: DetectionPrompt, outcome: PromptOutcome) {
    switch prompt {
    case .calendarStart(let meeting):
      openCalendarPrompt = false
      if outcome == .dismissed { dismissedEvents[meeting.id] = meeting.start }
    case .callJoined(_, let meeting):
      if outcome == .dismissed, let meeting { dismissedEvents[meeting.id] = meeting.start }
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

  private mutating func forgetOldEvents(_ now: Date) {
    let cutoff = now.addingTimeInterval(-Self.memory)
    promptedEvents = promptedEvents.filter { $0.value > cutoff }
    dismissedEvents = dismissedEvents.filter { $0.value > cutoff }
  }

  private mutating func whileRecording(_ input: DetectionInput) -> DetectionPrompt? {
    // A call already covered by a recording never asks to start afterwards,
    // and a meeting that starts mid-recording is part of it.
    for holder in input.micHolders { holds[holder]?.prompted = true }
    for meeting in inWindow(input) { promptedEvents[meeting.id] = meeting.start }
    // Calls on the mic when recording began count at once; one that starts
    // mid-recording counts only once it has run like a call.
    let joined =
      recordingCalls == nil
      ? input.micHolders
      : input.micHolders.filter { holder in
        holds[holder].map { input.now.timeIntervalSince($0.since) >= Self.midRecordingCallGrace }
          ?? false
      }
    let calls = (recordingCalls ?? []).union(joined)
    recordingCalls = calls
    recordedCallIsLive = calls.contains { holds[$0] != nil || input.callAudioHolders.contains($0) }
    // A call that comes back re-arms the prompt for its real end.
    if recordedCallIsLive {
      endPrompted = false
      return nil
    }
    // Ask once, when every call app in this recording has let go.
    guard !endPrompted, let ended = calls.sorted(by: Self.order).first else { return nil }
    endPrompted = true
    return .callEnded(ended)
  }

  private mutating func calendarPrompt(_ input: DetectionInput) -> DetectionPrompt? {
    let due = inWindow(input)
      .filter { promptedEvents[$0.id] == nil }
      .sorted(by: Self.linkedFirst)
    guard let meeting = due.first else { return nil }
    promptedEvents[meeting.id] = meeting.start
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
    // The open calendar prompt covers this call for now; if it expires
    // unanswered, the call still gets asked about.
    guard let holder = ready.first, !openCalendarPrompt else { return nil }
    // Apps joining together are one call: one prompt, not one per app.
    for app in ready { holds[app]?.prompted = true }
    let meeting = ongoing(input).first
    // "Not now" on a meeting covers its call too.
    if let meeting, dismissedEvents[meeting.id] != nil { return nil }
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

  private static func linkedFirst(_ lhs: CalendarMeeting, _ rhs: CalendarMeeting) -> Bool {
    CalendarMeeting.linkedFirst(lhs, rhs)
  }

  /// Meeting apps before browsers, then by name, so ties pick the same app.
  private static func order(_ lhs: MicHolder, _ rhs: MicHolder) -> Bool {
    if lhs.kind != rhs.kind { return lhs.kind == .meetingApp }
    return lhs.name < rhs.name
  }
}
