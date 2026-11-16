import Foundation

/// Someone on a calendar invite.
public struct MeetingAttendee: Codable, Equatable, Hashable, Sendable {
  public let name: String?
  public let email: String?
  /// The user themself (EventKit's `isCurrentUser`).
  public let isSelf: Bool

  public init(name: String?, email: String?, isSelf: Bool = false) {
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.name = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
    self.email = email?.lowercased()
    self.isSelf = isSelf
  }

  /// The invite's name, else the email's local part tidied
  /// ("maurice.lee@x" → "Maurice Lee").
  public var displayName: String {
    if let name {
      // Company directories list "Rivera, Ana"; people say "Ana Rivera".
      let parts = name.split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      return parts.count == 2 ? "\(parts[1]) \(parts[0])" : name
    }
    guard let local = email?.split(separator: "@").first else { return "Guest" }
    return local.split(whereSeparator: { ".-_+".contains($0) })
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  /// Rooms, resources and robot addresses ride along on invites but never
  /// speak; they would only add noise to names, hints and suggestions.
  public static func isPerson(name: String?, email: String?) -> Bool {
    let address = email?.lowercased() ?? ""
    let robots = [
      "resource.calendar", "@group.calendar", "noreply", "no-reply", "donotreply",
      "calendar-notification", "@resource.",
    ]
    return !robots.contains(where: address.contains)
  }
}

/// Groups occurrences of a recurring meeting (ported from the Myna app's
/// MeetingSeriesKey). EventKit gives every occurrence the same item ID; an
/// occurrence-specific "/RID=…" suffix is dropped. Without an ID, a title
/// stripped of digits and punctuation still groups "Standup 3/12" with
/// "Standup".
public enum MeetingSeries {
  public static func key(eventID: String?, title: String) -> String? {
    if let eventID, !eventID.isEmpty {
      let base = eventID.components(separatedBy: "/RID=").first ?? eventID
      if !base.isEmpty { return "event:" + base }
    }
    let words = String(
      title.lowercased().unicodeScalars.map {
        CharacterSet.letters.contains($0) ? Character($0) : " "
      }
    ).split(separator: " ")
    return words.isEmpty ? nil : "title:" + words.joined(separator: "-")
  }
}

/// The human-written part of an invite's notes: what's left after the
/// video-call footer (join links, meeting IDs, passcodes, dial-ins) is gone.
public enum InviteAgenda {
  public static let maxCharacters = 2_000

  private static let boilerplate = [
    "join zoom meeting", "zoom.us", "meeting id", "passcode", "password:", "dial by your location",
    "one tap mobile", "find your local number", "microsoft teams meeting",
    "join on your computer", "click here to join", "join the meeting now", "join with google meet",
    "join by phone", "more phone numbers", "learn more about meeting options", "meeting options",
    "this event has a video call", "webex", "need help?", "-::~:~::",
  ]

  /// Short footer lines matched whole (after trimming "<" and ":"), or as a
  /// line's start, so ordinary agenda sentences using these words survive.
  private static let footerLines: Set<String> = [
    "join", "more info", "dial in by phone", "find a local number",
    "join on a video conferencing device", "join from a video conferencing device",
  ]
  private static let footerPrefixes = [
    "phone conference id", "conference id", "tenant key", "video id", "dial in by phone",
  ]

  private static func isFooter(_ line: String) -> Bool {
    let core = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \t<>:"))
    return footerLines.contains(core) || footerPrefixes.contains(where: core.hasPrefix)
  }

  public static func clean(_ notes: String?) -> String? {
    guard let notes else { return nil }
    var lines: [String] = []
    for raw in notes.components(separatedBy: .newlines) {
      let lowered = raw.lowercased()
      if boilerplate.contains(where: lowered.contains) || isSeparator(raw) || isDialIn(raw)
        || isFooter(raw)
      {
        continue
      }
      let line = removingURLs(raw).trimmingCharacters(in: .whitespaces)
      // Collapse runs of blank lines into one.
      if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
      lines.append(line)
    }
    let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.contains(where: \.isLetter) else { return nil }
    guard text.count > maxCharacters else { return text }
    let cut = text.prefix(maxCharacters)
    return String(cut[..<(cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex)]) + "…"
  }

  private static func isSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 5 && Set(trimmed).count == 1
  }

  /// "+1 646 558 8656 US (New York)" and similar.
  private static func isDialIn(_ line: String) -> Bool {
    line.range(of: #"^\s*\+?\d[\d \-\(\)\.,#*]{7,}"#, options: .regularExpression) != nil
  }

  private static func removingURLs(_ line: String) -> String {
    line.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
  }
}

/// What a recording knows about the meeting it is for. Snapshotted when
/// recording starts: calendar caches move on, the meeting record doesn't.
public struct MeetingContext: Codable, Equatable, Sendable {
  public var title: String?
  public var eventID: String?
  public var seriesKey: String?
  public var attendees: [MeetingAttendee]
  public var organizer: String?
  public var agenda: String?

  public init(
    title: String? = nil, eventID: String? = nil, seriesKey: String? = nil,
    attendees: [MeetingAttendee] = [], organizer: String? = nil, agenda: String? = nil
  ) {
    self.title = title
    self.eventID = eventID
    self.seriesKey = seriesKey
    self.attendees = attendees
    self.organizer = organizer
    self.agenda = agenda
  }

  public init(_ meeting: CalendarMeeting) {
    self.init(
      title: meeting.title, eventID: meeting.eventID,
      seriesKey: MeetingSeries.key(eventID: meeting.eventID, title: meeting.title),
      attendees: meeting.attendees, organizer: meeting.organizer, agenda: meeting.agenda)
  }

  /// Everyone on the invite except the user.
  public var others: [MeetingAttendee] { attendees.filter { !$0.isSelf } }
}
