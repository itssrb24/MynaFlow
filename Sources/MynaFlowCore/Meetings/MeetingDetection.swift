import Foundation

/// A timed calendar event, already filtered by the calendar adapter (no
/// all-day events, none the user declined).
public struct CalendarMeeting: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let start: Date
  public let end: Date
  /// A video-call link from the event, when it has one.
  public let link: URL?

  public init(id: String, title: String, start: Date, end: Date, link: URL?) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.link = link
  }

  /// The meeting happening at `date` (or starting within `leadTime`), so
  /// notes started by hand still carry the meeting's name. Overlapping
  /// events prefer one with a video link, then the earliest start.
  public static func current(
    in events: [CalendarMeeting], at date: Date, leadTime: TimeInterval = 60
  ) -> CalendarMeeting? {
    events
      .filter { date >= $0.start.addingTimeInterval(-leadTime) && date < $0.end }
      .sorted(by: linkedFirst)
      .first
  }

  /// Events with a video link first, then the earliest start.
  static func linkedFirst(_ lhs: CalendarMeeting, _ rhs: CalendarMeeting) -> Bool {
    if (lhs.link != nil) != (rhs.link != nil) { return lhs.link != nil }
    return lhs.start < rhs.start
  }
}

/// An app using the microphone that could mean a call: a meeting app or a
/// browser (Google Meet, Teams on the web). Never Myna Flow itself.
public struct MicHolder: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case meetingApp
    case browser
  }

  /// The catalog's bundle ID — helper processes are folded into their app.
  public let bundleID: String
  public let name: String
  public let kind: Kind

  public init(bundleID: String, name: String, kind: Kind) {
    self.bundleID = bundleID
    self.name = name
    self.kind = kind
  }
}

/// One tick's view of the world.
public struct DetectionInput: Sendable {
  public let now: Date
  public let events: [CalendarMeeting]
  public let micHolders: Set<MicHolder>
  /// Call apps playing audio. A call app that releases the mic while the
  /// user is muted keeps playing the others, so it is still on the call.
  public let callAudioHolders: Set<MicHolder>
  public let isRecording: Bool

  public init(
    now: Date, events: [CalendarMeeting], micHolders: Set<MicHolder>,
    callAudioHolders: Set<MicHolder> = [], isRecording: Bool
  ) {
    self.now = now
    self.events = events
    self.micHolders = micHolders
    self.callAudioHolders = callAudioHolders
    self.isRecording = isRecording
  }
}

/// What the detector asks the user. It only ever asks — recording starts or
/// stops on the user's answer, or (for `.callEnded`) when that ask expires.
public enum DetectionPrompt: Sendable, Equatable {
  case calendarStart(CalendarMeeting)
  case callJoined(MicHolder, meeting: CalendarMeeting?)
  case callEnded(MicHolder)
}

/// How a prompt was answered.
public enum PromptOutcome: Sendable {
  case accepted
  /// "Not now" / "Keep recording": don't ask about this again.
  case dismissed
  /// Timed out unseen — a later signal for the same meeting may still ask.
  case expired
}
