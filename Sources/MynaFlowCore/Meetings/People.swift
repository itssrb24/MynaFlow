import Foundation

/// Someone met in meetings: from an invite (keyed by email) or named by
/// the user. Voice profiles, when the user opts in, attach here.
public struct Person: Identifiable, Equatable, Hashable, Sendable {
  public let id: UUID
  public let name: String
  public let email: String?

  public init(id: UUID = UUID(), name: String, email: String?) {
    self.id = id
    self.name = name
    self.email = email
  }
}

/// Who an unnamed speaker probably is: the people on the invite not yet
/// given to a speaker, then the names from the last meeting in the series.
public enum SpeakerSuggestions {
  public static func names(for meeting: MeetingRecord, previous: MeetingRecord?) -> [String] {
    let taken = Set(meeting.speakerNames.values.map { $0.lowercased() })
    var seen = taken
    var names: [String] = []
    let candidates =
      (meeting.context?.others.map(\.displayName) ?? [])
      + (previous?.speakerNames.sorted { $0.key < $1.key }.map(\.value) ?? [])
    for name in candidates where seen.insert(name.lowercased()).inserted {
      names.append(name)
    }
    return names
  }
}
