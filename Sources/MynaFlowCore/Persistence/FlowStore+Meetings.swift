import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension FlowStore {
  public func insertMeeting(_ record: MeetingRecord) throws {
    let encoder = JSONEncoder()
    let segments = String(decoding: try encoder.encode(record.segments), as: UTF8.self)
    let keyPoints = try record.summary.map {
      String(decoding: try encoder.encode($0.keyPoints), as: UTF8.self)
    }
    let actionItems = try record.summary.map {
      String(decoding: try encoder.encode($0.actionItems), as: UTF8.self)
    }
    let names = record.speakerNames.isEmpty ? nil : try Self.encodeNames(record.speakerNames)
    let context = try record.context.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    let profiles = record.speakerProfiles.isEmpty
      ? nil : String(decoding: try encoder.encode(record.speakerProfiles), as: UTF8.self)
    let suggestions = record.speakerSuggestions.isEmpty ? nil : try Self.encodeLinks(record.speakerSuggestions)
    let people = record.speakerPeople.isEmpty ? nil : try Self.encodeLinks(record.speakerPeople)
    let decisions = try record.summary.map {
      String(decoding: try encoder.encode($0.decisions), as: UTF8.self)
    }
    try run(
      """
      INSERT INTO meetings (
        id, started_at, duration_seconds, segments, key_points, action_items, summary_note,
        event_title, speaker_names, context, series_key, overview, decisions, meeting_type,
        summary_basis, speaker_people, speaker_profiles, speaker_suggestions
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, transient)
        sqlite3_bind_double(statement, 2, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, record.durationSeconds)
        sqlite3_bind_text(statement, 4, segments, -1, transient)
        bindText(statement, 5, keyPoints)
        bindText(statement, 6, actionItems)
        bindText(statement, 7, record.summaryNote)
        bindText(statement, 8, record.eventTitle)
        bindText(statement, 9, names)
        bindText(statement, 10, context)
        bindText(statement, 11, record.context?.seriesKey)
        bindText(statement, 12, record.summary?.overview)
        bindText(statement, 13, decisions)
        bindText(statement, 14, record.meetingType?.rawValue)
        bindText(statement, 15, record.summaryBasis)
        bindText(statement, 16, people)
        bindText(statement, 17, profiles)
        bindText(statement, 18, suggestions)
      })
    try upsertPeople(record.context?.others ?? [])
  }

  /// Replaces a meeting's summary, note, type and basis ("Update summary").
  public func updateSummary(of record: MeetingRecord) throws {
    let encoder = JSONEncoder()
    func json(_ list: [String]?) throws -> String? {
      try list.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    }
    let keyPoints = try json(record.summary?.keyPoints)
    let actionItems = try json(record.summary?.actionItems)
    let decisions = try json(record.summary?.decisions)
    let key = record.id.uuidString
    try run(
      """
      UPDATE meetings SET key_points = ?1, action_items = ?2, summary_note = ?3, overview = ?4,
        decisions = ?5, meeting_type = ?6, summary_basis = ?7 WHERE id = ?8
      """,
      bind: { statement in
        bindText(statement, 1, keyPoints)
        bindText(statement, 2, actionItems)
        bindText(statement, 3, record.summaryNote)
        bindText(statement, 4, record.summary?.overview)
        bindText(statement, 5, decisions)
        bindText(statement, 6, record.meetingType?.rawValue)
        bindText(statement, 7, record.summaryBasis)
        sqlite3_bind_text(statement, 8, key, -1, transient)
      })
  }

  /// Attaches an invite to a meeting after the fact ("Link to calendar
  /// event…"); its title becomes the meeting's name.
  public func setMeetingContext(_ context: MeetingContext, meetingID: UUID) throws {
    let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    let key = meetingID.uuidString
    try run(
      "UPDATE meetings SET context = ?1, series_key = ?2, event_title = ?3 WHERE id = ?4",
      bind: { statement in
        bindText(statement, 1, json)
        bindText(statement, 2, context.seriesKey)
        bindText(statement, 3, context.title)
        sqlite3_bind_text(statement, 4, key, -1, transient)
      })
  }

  /// Earlier meetings of the same recurring series, newest first.
  public func meetings(inSeries seriesKey: String, before date: Date, limit: Int = 3) throws
    -> [MeetingRecord]
  {
    try query(
      """
      SELECT \(Self.meetingColumns) FROM meetings
      WHERE series_key = ?1 AND started_at < ?2 ORDER BY started_at DESC LIMIT ?3
      """,
      bind: { statement in
        sqlite3_bind_text(statement, 1, seriesKey, -1, transient)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(limit))
      },
      row: Self.readMeeting)
  }

  private static let meetingColumns = """
    id, started_at, duration_seconds, segments, key_points, action_items, summary_note,
      event_title, speaker_names, context, overview, decisions, meeting_type, summary_basis,
      speaker_people, speaker_profiles, speaker_suggestions
    """

  // MARK: - People

  /// Everyone met in meetings, by name.
  public func people() throws -> [Person] {
    try query(
      "SELECT id, name, email FROM people ORDER BY name COLLATE NOCASE",
      bind: { _ in },
      row: { statement in
        guard let id = text(statement, 0).flatMap(UUID.init(uuidString:)), let name = text(statement, 1)
        else { throw FlowStoreError(message: "malformed person row") }
        return Person(id: id, name: name, email: text(statement, 2))
      })
  }

  /// Invitees become people, one per email. A name from the invite replaces
  /// one guessed from an address; a guess never replaces a real name.
  func upsertPeople(_ attendees: [MeetingAttendee]) throws {
    for attendee in attendees {
      guard let email = attendee.email else { continue }
      try run(
        """
        INSERT INTO people (id, name, email, created_at) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(email) DO UPDATE SET name = CASE WHEN ?5 = 1 THEN excluded.name ELSE name END
        """,
        bind: { statement in
          sqlite3_bind_text(statement, 1, UUID().uuidString, -1, transient)
          sqlite3_bind_text(statement, 2, attendee.displayName, -1, transient)
          sqlite3_bind_text(statement, 3, email, -1, transient)
          sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
          sqlite3_bind_int(statement, 5, attendee.name == nil ? 0 : 1)
        })
    }
  }

  /// The person with this name (ignoring case), created if there is none —
  /// for a name typed by hand rather than picked from an invite.
  public func person(named name: String) throws -> Person {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let existing = try people().first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      return existing
    }
    let person = Person(name: trimmed, email: nil)
    try run(
      "INSERT INTO people (id, name, email, created_at) VALUES (?1, ?2, NULL, ?3)",
      bind: { statement in
        sqlite3_bind_text(statement, 1, person.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, trimmed, -1, transient)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
      })
    return person
  }

  /// Says a speaker was this person: names the speaker, records the link
  /// (voice profiles enrol through it), and teaches the name to vocabulary.
  /// With `learnVoice` (voices opted in), a clean speaker profile also
  /// teaches the person's voice — and is taken back out of whoever it
  /// taught before, so a correction never leaves a wrong voice behind.
  public func setSpeaker(_ speaker: Int, to person: Person, meetingID: UUID, learnVoice: Bool = false)
    throws
  {
    try setSpeakerName(person.name, speaker: speaker, meetingID: meetingID)
    var links = try speakerPeople(meetingID: meetingID)
    links[speaker] = person.id
    try writeSpeakerPeople(links, meetingID: meetingID)
    if learnVoice { try enrolVoice(of: speaker, into: person.id, meetingID: meetingID) }
  }

  // MARK: - Voices

  /// A person's voice profiles (empty unless the user taught one).
  public func voicePrints(of personID: UUID) throws -> [VoicePrint] {
    let key = personID.uuidString
    let stored = try query(
      "SELECT voiceprint FROM people WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, key, -1, transient) },
      row: { text($0, 0) }
    ).first ?? nil
    return try stored.map { try JSONDecoder().decode([VoicePrint].self, from: Data($0.utf8)) } ?? []
  }

  /// Everyone with a voice profile, as candidates for recognising a
  /// meeting's speakers; invitees (by email) get the matcher's small nudge.
  public func voiceCandidates(invited emails: Set<String>) throws -> [SpeakerMatch.Candidate] {
    try query(
      "SELECT id, email, voiceprint FROM people WHERE voiceprint IS NOT NULL",
      bind: { _ in },
      row: { statement in
        guard let id = text(statement, 0).flatMap(UUID.init(uuidString:)), let json = text(statement, 2)
        else { throw FlowStoreError(message: "malformed person row") }
        let prints = try JSONDecoder().decode([VoicePrint].self, from: Data(json.utf8))
        return SpeakerMatch.Candidate(
          personID: id, voiceprints: prints, isInvited: text(statement, 1).map(emails.contains) ?? false)
      }
    ).filter { !$0.voiceprints.isEmpty }
  }

  /// Deletes every voice profile and every meeting's stored speaker samples.
  public func forgetAllVoices() throws {
    try run("UPDATE people SET voiceprint = NULL, voiceprint_samples = 0", bind: { _ in })
    try run("UPDATE meetings SET speaker_profiles = NULL, speaker_suggestions = NULL", bind: { _ in })
  }

  private func writeVoicePrints(_ prints: [VoicePrint], of personID: UUID) throws {
    let json = prints.isEmpty ? nil : String(decoding: try JSONEncoder().encode(prints), as: UTF8.self)
    let key = personID.uuidString
    try run(
      "UPDATE people SET voiceprint = ?1, voiceprint_samples = ?2 WHERE id = ?3",
      bind: { statement in
        bindText(statement, 1, json)
        sqlite3_bind_int(statement, 2, Int32(prints.map(\.sampleCount).reduce(0, +)))
        sqlite3_bind_text(statement, 3, key, -1, transient)
      })
  }

  private func writeProfiles(_ profiles: [SpeakerProfile], meetingID: UUID) throws {
    let json = profiles.isEmpty ? nil : String(decoding: try JSONEncoder().encode(profiles), as: UTF8.self)
    let key = meetingID.uuidString
    try run(
      "UPDATE meetings SET speaker_profiles = ?1 WHERE id = ?2",
      bind: { statement in
        bindText(statement, 1, json)
        sqlite3_bind_text(statement, 2, key, -1, transient)
      })
  }

  /// Teaches `personID` this speaker's voice when its profile is clean,
  /// first taking it back out of anyone it taught before (Myna's exact
  /// inverse), and records who it taught.
  private func enrolVoice(of speaker: Int, into personID: UUID?, meetingID: UUID) throws {
    guard let meeting = try meeting(id: meetingID),
      var profile = meeting.speakerProfiles.first(where: { $0.speaker == speaker })
    else { return }
    if let previous = profile.enrolledPerson {
      guard previous != personID else { return }
      let reduced = SpeakerMatch.unenroll(
        embedding: profile.embedding, channel: .remote, from: try voicePrints(of: previous), at: Date())
      try writeVoicePrints(reduced, of: previous)
      profile.enrolledPerson = nil
    }
    if let personID, profile.quality.allowsEnrollment {
      let grown = SpeakerMatch.enroll(
        embedding: profile.embedding, channel: .remote, into: try voicePrints(of: personID), at: Date())
      try writeVoicePrints(grown, of: personID)
      profile.enrolledPerson = personID
    }
    let others = meeting.speakerProfiles.filter { $0.speaker != speaker }
    try writeProfiles((others + [profile]).sorted { $0.speaker < $1.speaker }, meetingID: meetingID)
  }

  /// "Same person": every line of `from` becomes `into`'s, and `from`'s name
  /// and person link go.
  public func mergeSpeaker(_ from: Int, into: Int, meetingID: UUID) throws {
    guard let meeting = try meeting(id: meetingID) else { return }
    let segments = meeting.segments.map {
      $0.speaker == from
        ? MeetingSegment(channel: $0.channel, startSeconds: $0.startSeconds, text: $0.text, speaker: into)
        : $0
    }
    let json = String(decoding: try JSONEncoder().encode(segments), as: UTF8.self)
    let key = meetingID.uuidString
    try run(
      "UPDATE meetings SET segments = ?1 WHERE id = ?2",
      bind: { statement in
        sqlite3_bind_text(statement, 1, json, -1, transient)
        sqlite3_bind_text(statement, 2, key, -1, transient)
      })
    try setSpeakerName("", speaker: from, meetingID: meetingID)
    var links = meeting.speakerPeople
    links[from] = nil
    try writeSpeakerPeople(links, meetingID: meetingID)
  }

  func meeting(id: UUID) throws -> MeetingRecord? {
    let key = id.uuidString
    return try query(
      "SELECT \(Self.meetingColumns) FROM meetings WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, key, -1, transient) },
      row: Self.readMeeting
    ).first
  }

  private func speakerPeople(meetingID: UUID) throws -> [Int: UUID] {
    try meeting(id: meetingID)?.speakerPeople ?? [:]
  }

  private static func encodeLinks(_ links: [Int: UUID]) throws -> String {
    let byKey = Dictionary(uniqueKeysWithValues: links.map { (String($0.key), $0.value.uuidString) })
    return String(decoding: try JSONEncoder().encode(byKey), as: UTF8.self)
  }

  private func writeSpeakerPeople(_ links: [Int: UUID], meetingID: UUID) throws {
    let json = links.isEmpty ? nil : try Self.encodeLinks(links)
    let key = meetingID.uuidString
    try run(
      "UPDATE meetings SET speaker_people = ?1 WHERE id = ?2",
      bind: { statement in
        bindText(statement, 1, json)
        sqlite3_bind_text(statement, 2, key, -1, transient)
      })
  }

  private static func decodePeople(_ json: String) throws -> [Int: UUID] {
    let byKey = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    return Dictionary(uniqueKeysWithValues: byKey.compactMap { key, value in
      guard let number = Int(key), let id = UUID(uuidString: value) else { return nil }
      return (number, id)
    })
  }

  /// Names (or, with a blank name, un-names) one speaker in one meeting.
  /// A real name also joins the vocabulary, so the engine hears it next time.
  public func setSpeakerName(_ name: String, speaker: Int, meetingID: UUID) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedName.isEmpty { try addVocabularyTerm(trimmedName, source: .promoted) }
    let key = meetingID.uuidString
    let stored = try query(
      "SELECT speaker_names FROM meetings WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, key, -1, transient) },
      row: { text($0, 0) }
    ).first ?? nil
    var names = try stored.map(Self.decodeNames) ?? [:]
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    names[speaker] = trimmed.isEmpty ? nil : trimmed
    let json = names.isEmpty ? nil : try Self.encodeNames(names)
    try run(
      "UPDATE meetings SET speaker_names = ?1 WHERE id = ?2",
      bind: { statement in
        bindText(statement, 1, json)
        sqlite3_bind_text(statement, 2, key, -1, transient)
      })
    // A new name means a new identity; setSpeaker re-links when it's a person.
    var links = try speakerPeople(meetingID: meetingID)
    if links.removeValue(forKey: speaker) != nil { try writeSpeakerPeople(links, meetingID: meetingID) }
    // Whatever voice this speaker taught goes with the old name.
    try enrolVoice(of: speaker, into: nil, meetingID: meetingID)
  }

  // JSON object keys are strings; speaker numbers become "1", "2", ….
  private static func encodeNames(_ names: [Int: String]) throws -> String {
    let byKey = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
    return String(decoding: try JSONEncoder().encode(byKey), as: UTF8.self)
  }

  private static func decodeNames(_ json: String) throws -> [Int: String] {
    let byKey = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    return Dictionary(uniqueKeysWithValues: byKey.compactMap { key, value in
      Int(key).map { ($0, value) }
    })
  }

  /// Newest first.
  public func meetings(limit: Int) throws -> [MeetingRecord] {
    try query(
      """
      SELECT \(Self.meetingColumns)
      FROM meetings ORDER BY started_at DESC LIMIT ?1
      """,
      bind: { sqlite3_bind_int($0, 1, Int32(limit)) },
      row: Self.readMeeting)
  }

  public func deleteMeeting(id: UUID) throws {
    let key = id.uuidString
    try run(
      "DELETE FROM meetings WHERE id = ?1",
      bind: { sqlite3_bind_text($0, 1, key, -1, transient) })
  }

  private static func readMeeting(_ statement: OpaquePointer) throws -> MeetingRecord {
    let decoder = JSONDecoder()
    guard let idText = text(statement, 0), let id = UUID(uuidString: idText),
      let segmentsJSON = text(statement, 3)
    else { throw FlowStoreError(message: "malformed meeting row") }
    let segments = try decoder.decode([MeetingSegment].self, from: Data(segmentsJSON.utf8))
    let summary: MeetingSummary? =
      if let points = text(statement, 4), let actions = text(statement, 5) {
        MeetingSummary(
          overview: text(statement, 10),
          decisions: try text(statement, 11).map {
            try decoder.decode([String].self, from: Data($0.utf8))
          } ?? [],
          keyPoints: try decoder.decode([String].self, from: Data(points.utf8)),
          actionItems: try decoder.decode([String].self, from: Data(actions.utf8)))
      } else {
        nil
      }
    return MeetingRecord(
      id: id,
      startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      durationSeconds: sqlite3_column_double(statement, 2),
      segments: segments,
      summary: summary,
      summaryNote: text(statement, 6),
      eventTitle: text(statement, 7),
      speakerNames: try text(statement, 8).map(decodeNames) ?? [:],
      context: try text(statement, 9).map {
        try decoder.decode(MeetingContext.self, from: Data($0.utf8))
      },
      meetingType: text(statement, 12).flatMap(MeetingType.init(rawValue:)),
      summaryBasis: text(statement, 13),
      speakerPeople: try text(statement, 14).map(decodePeople) ?? [:],
      speakerProfiles: try text(statement, 15).map {
        try decoder.decode([SpeakerProfile].self, from: Data($0.utf8))
      } ?? [],
      speakerSuggestions: try text(statement, 16).map(decodePeople) ?? [:])
  }
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
  guard sqlite3_column_type(statement, index) != SQLITE_NULL,
    let cString = sqlite3_column_text(statement, index)
  else { return nil }
  return String(cString: cString)
}

private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
  if let value {
    sqlite3_bind_text(statement, index, value, -1, transient)
  } else {
    sqlite3_bind_null(statement, index)
  }
}
