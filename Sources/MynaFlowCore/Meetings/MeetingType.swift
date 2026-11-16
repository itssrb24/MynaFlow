import Foundation

/// The kind of meeting, read from the invite. It tunes what the summary
/// pays attention to; it never changes what is recorded.
public enum MeetingType: String, Codable, CaseIterable, Sendable {
  case general, oneOnOne, standup, planning, review, client, interview

  public var displayName: String {
    switch self {
    case .general: "Meeting"
    case .oneOnOne: "1:1"
    case .standup: "Standup"
    case .planning: "Planning"
    case .review: "Review"
    case .client: "Client"
    case .interview: "Interview"
    }
  }

  /// One paragraph swapped into the summary prompt.
  var focus: String {
    switch self {
    case .general: "Focus on decisions, open questions and who is doing what next."
    case .oneOnOne:
      "This is a one-on-one. Focus on feedback given, concerns raised, commitments each person made, and follow-ups."
    case .standup:
      "This is a standup. Summarize each person's update and call out blockers and anything that needs help."
    case .planning:
      "This is a planning meeting. Focus on priorities, scope, dates and owners agreed, and what is still undecided."
    case .review:
      "This is a review or retrospective. Focus on what went well, what didn't, and the changes agreed."
    case .client:
      "This is a meeting with people outside the team. Focus on their needs and concerns, commitments made to them, and next steps."
    case .interview:
      "This is an interview. Focus on the questions asked, the candidate's answers and evidence, and any concerns."
    }
  }

  /// Keyword rules over the title and agenda, then attendee count and
  /// whether anyone is from another company.
  public static func infer(title: String?, agenda: String?, attendeeCount: Int, external: Bool) -> MeetingType {
    let text = ((title ?? "") + " " + (agenda ?? "")).lowercased()
    let rules: [(MeetingType, [String])] = [
      (.interview, ["interview", "candidate", "screening"]),
      (.standup, ["standup", "stand-up", "stand up", "daily sync", "scrum"]),
      (.review, ["retro", "retrospective", "post-mortem", "postmortem", "review"]),
      (.planning, ["planning", "roadmap", "kickoff", "kick-off", "okr", "sprint plan"]),
      (.oneOnOne, ["1:1", "1-1", "one on one", "one-on-one", "1 on 1", "check-in", "coffee"]),
    ]
    if let match = rules.first(where: { $0.1.contains(where: text.contains) }) { return match.0 }
    if external { return .client }
    return attendeeCount == 2 ? .oneOnOne : .general
  }

  private static let personalDomains: Set<String> = [
    "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com",
    "hotmail.com", "live.com", "yahoo.com", "proton.me", "protonmail.com", "aol.com",
  ]

  /// Whether someone on the invite is from a company domain other than the
  /// user's. Personal mail doesn't count either way.
  public static func hasExternal(_ attendees: [MeetingAttendee]) -> Bool {
    func domain(_ person: MeetingAttendee) -> String? {
      person.email?.split(separator: "@").last.map(String.init)
    }
    guard let mine = attendees.first(where: \.isSelf).flatMap(domain),
      !personalDomains.contains(mine)
    else { return false }
    return attendees.contains { person in
      guard !person.isSelf, let theirs = domain(person) else { return false }
      return theirs != mine && !personalDomains.contains(theirs)
    }
  }
}
