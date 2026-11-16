import Foundation

/// The last meeting of the same series, so this summary can say what
/// moved on since.
public struct PreviousMeeting: Equatable, Sendable {
  public let overview: String?
  public let openActions: [String]

  public init(overview: String?, openActions: [String]) {
    self.overview = overview
    self.openActions = openActions
  }
}

/// What the summary knows besides the transcript: the invite, the names
/// given to speakers, the kind of meeting, and the last one in its series.
public struct SummaryContext: Equatable, Sendable {
  public var title: String?
  public var attendees: [String]
  public var organizer: String?
  public var agenda: String?
  public var speakerNames: [Int: String]
  public var type: MeetingType
  public var previous: PreviousMeeting?

  public init(
    title: String? = nil, attendees: [String] = [], organizer: String? = nil, agenda: String? = nil,
    speakerNames: [Int: String] = [:], type: MeetingType = .general, previous: PreviousMeeting? = nil
  ) {
    self.title = title
    self.attendees = attendees
    self.organizer = organizer
    self.agenda = agenda
    self.speakerNames = speakerNames
    self.type = type
    self.previous = previous
  }
}

public enum MeetingSummaryOutcome: Equatable, Sendable {
  case summarized(MeetingSummary)
  /// No summary was attempted; the string says why, for the user.
  case unavailable(String)
  case failed(String)
}

/// Summarizes a meeting with the local Gemma model, map-reduce style: each
/// transcript part becomes notes, then the notes are merged in rounds of
/// batches that fit the notes budget until one summary is left. The model
/// never sees more than one part, or one batch of notes, at a time, so a
/// long meeting fits a small context window.
public struct MeetingSummarizer: Sendable {
  public static let noModelNote =
    "No summary: no language model is installed. Install one in Models to summarize meetings."
  public static let emptyNote = "No summary: nothing was transcribed."
  public static let maxDecisions = 6
  public static let maxKeyPoints = 8
  public static let maxActionItems = 8

  private let model: (any LocalLanguageModel)?
  private let maxPartCharacters: Int
  private let maxNotesCharacters: Int

  /// `maxPartCharacters` bounds each transcript part sent to the model;
  /// `maxNotesCharacters` bounds the notes in each merge prompt.
  public init(
    model: (any LocalLanguageModel)?, maxPartCharacters: Int = 6_000,
    maxNotesCharacters: Int = 6_000
  ) {
    self.model = model
    self.maxPartCharacters = maxPartCharacters
    self.maxNotesCharacters = maxNotesCharacters
  }

  public func summarize(_ segments: [MeetingSegment], context: SummaryContext = SummaryContext())
    async -> MeetingSummaryOutcome
  {
    guard let model else { return .unavailable(Self.noModelNote) }
    let parts = Self.split(segments, maxCharacters: maxPartCharacters, names: context.speakerNames)
    guard !parts.isEmpty else { return .unavailable(Self.emptyNote) }
    let header = Self.contextHeader(context)
    do {
      var notes: [String] = []
      for (index, part) in parts.enumerated() {
        let prompt = Self.mapPrompt(part, header: header, part: index + 1, of: parts.count)
        notes.append(try await model.generateInstruction(prompt, maxTokens: 768))
      }
      let (final, lastPrompt) = try await reduce(
        notes, header: header, with: model,
        singlePrompt: Self.mapPrompt(parts[0], header: header, part: 1, of: 1))
      // Small models sometimes answer in prose; ask once more before giving up.
      var summary = Self.parse(final)
      if summary == nil {
        summary = Self.parse(try await model.generateInstruction(lastPrompt, maxTokens: 1_024))
      }
      guard let summary else { return .failed("The model's summary could not be read.") }
      return .summarized(summary)
    } catch {
      // Type only: an error may carry model output, which is the user's words.
      return .failed("Summary failed (\(type(of: error))).")
    }
  }

  /// Merges notes batch by batch until one is left; also returns the prompt
  /// that produced it, for a retry.
  private func reduce(
    _ notes: [String], header: String, with model: any LocalLanguageModel, singlePrompt: String
  ) async throws -> (String, String) {
    var round = notes
    var lastPrompt = singlePrompt
    while round.count > 1 {
      var merged: [String] = []
      for batch in Self.batches(round, maxCharacters: maxNotesCharacters) {
        if batch.count == 1 {
          merged.append(batch[0])
        } else {
          lastPrompt = Self.reducePrompt(batch, header: header)
          merged.append(try await model.generateInstruction(lastPrompt, maxTokens: 1_024))
        }
      }
      round = merged
    }
    return (round[0], lastPrompt)
  }

  /// Groups notes so each merge prompt's notes fit `maxCharacters`. A batch
  /// always takes at least two notes, so every round shrinks the list and
  /// the merge ends even when single notes are long.
  static func batches(_ notes: [String], maxCharacters: Int) -> [[String]] {
    var batches: [[String]] = []
    var current: [String] = []
    for note in notes {
      if current.count >= 2, renderNotes(current + [note]).count > maxCharacters {
        batches.append(current)
        current = []
      }
      current.append(note)
    }
    if !current.isEmpty { batches.append(current) }
    return batches
  }

  // MARK: - Prompts

  private static let format = """
    Reply in exactly this format and nothing else:
    OVERVIEW:
    <two or three sentences on what the meeting was about and what it concluded>
    DECISIONS:
    - <decision>
    KEY POINTS:
    - <point>
    ACTION ITEMS:
    - <owner> — <task, with the due date if one was said>
    Write "- None" under a heading with nothing to list.
    Never invent an owner: name a person only if the transcript says who will do it; \
    otherwise write "Unassigned". Use the invite's names only for people heard in the transcript.
    """

  /// The invite, speaker names, meeting kind and the last meeting in the
  /// series, rendered once and repeated in every prompt.
  static func contextHeader(_ context: SummaryContext) -> String {
    var lines: [String] = []
    if let title = context.title { lines.append("Meeting: \(title) (\(context.type.displayName))") }
    if !context.attendees.isEmpty {
      let people = context.attendees.map { $0 == context.organizer ? "\($0) (organizer)" : $0 }
      lines.append("Invited: " + people.joined(separator: ", "))
    }
    if let agenda = context.agenda { lines.append("Agenda from the invite:\n" + agenda) }
    if let previous = context.previous {
      var recap = "Last meeting in this series:"
      if let overview = previous.overview { recap += " " + overview }
      if !previous.openActions.isEmpty {
        recap += "\nStill open from then:\n" + previous.openActions.map { "- " + $0 }.joined(separator: "\n")
      }
      lines.append(recap + "\nSay what moved on since, where the transcript shows it.")
    }
    lines.append(context.type.focus)
    return lines.joined(separator: "\n")
  }

  static func mapPrompt(_ transcriptPart: String, header: String = "", part: Int = 1, of total: Int = 1)
    -> String
  {
    let which = total > 1 ? "part \(part) of \(total) of a meeting transcript" : "a meeting transcript"
    return """
      You are writing meeting notes for the person who took them, shown as "You". \
      "Others" or a speaker's name is someone else on the call.
      \(header)

      Below is \(which). Extract the decisions, key points and action items.

      \(format)

      Transcript:
      \(transcriptPart)
      """
  }

  private static func renderNotes(_ notes: [String]) -> String {
    notes.enumerated()
      .map { "Notes from part \($0.offset + 1):\n\($0.element)" }
      .joined(separator: "\n\n")
  }

  static func reducePrompt(_ notes: [String], header: String = "") -> String {
    let rendered = renderNotes(notes)
    return """
      These are notes from consecutive parts of one meeting.
      \(header)

      Merge them into a single summary: combine duplicates, keep every distinct decision and task.

      \(format)

      \(rendered)
      """
  }

  /// Section headings spoken in a meeting must not pose as the summary's
  /// own: "ACTION ITEMS:" in the transcript becomes "action items -".
  static func sanitize(_ line: String) -> String {
    var out = line
    for heading in ["OVERVIEW", "DECISIONS", "KEY POINTS", "ACTION ITEMS"] {
      out = out.replacingOccurrences(
        of: heading + ":", with: heading.lowercased() + " -", options: .caseInsensitive)
    }
    return out
  }

  /// Packs whole transcript lines into parts of at most `maxCharacters`. A
  /// single over-long line becomes its own part rather than being cut.
  static func split(_ segments: [MeetingSegment], maxCharacters: Int, names: [Int: String] = [:])
    -> [String]
  {
    var parts: [String] = []
    var current = ""
    for segment in segments where !segment.text.isEmpty {
      let line = sanitize(MeetingTranscript.line(segment, names: names))
      if !current.isEmpty, current.count + 1 + line.count > maxCharacters {
        parts.append(current)
        current = ""
      }
      current = current.isEmpty ? line : current + "\n" + line
    }
    if !current.isEmpty { parts.append(current) }
    return parts
  }

  // MARK: - Parsing

  private enum Section { case overview, decisions, keyPoints, actionItems }

  private static let headings: [String: Section] = [
    "overview": .overview, "decisions": .decisions, "key points": .keyPoints,
    "action items": .actionItems,
  ]

  /// Reads the headed sections, tolerating Markdown decoration, and caps each
  /// list in code — a small model asked for eight items may return twenty.
  /// Nil when no heading is present: prose is not a summary.
  static func parse(_ output: String) -> MeetingSummary? {
    var section: Section?
    var sawHeading = false
    var overview: [String] = []
    var decisions: [String] = []
    var keyPoints: [String] = []
    var actionItems: [String] = []
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let heading = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
      if let next = headings[heading] {
        section = next
        sawHeading = true
        continue
      }
      guard let section else { continue }
      if section == .overview {
        let text = bulletText(line) ?? line
        if !text.isEmpty { overview.append(text) }
        continue
      }
      guard let item = bulletText(line),
        item.lowercased().trimmingCharacters(in: .punctuationCharacters) != "none"
      else { continue }
      switch section {
      case .overview: break
      case .decisions: decisions.append(item)
      case .keyPoints: keyPoints.append(item)
      case .actionItems: actionItems.append(item)
      }
    }
    guard sawHeading else { return nil }
    let summaryText = overview.joined(separator: " ")
    return MeetingSummary(
      overview: summaryText.isEmpty || summaryText.lowercased() == "none" ? nil : summaryText,
      decisions: Array(decisions.prefix(maxDecisions)),
      keyPoints: Array(keyPoints.prefix(maxKeyPoints)),
      actionItems: Array(actionItems.prefix(maxActionItems)))
  }

  private static func bulletText(_ line: String) -> String? {
    var text = Substring(line)
    if let first = text.first, "-*•".contains(first) {
      text = text.dropFirst()
    } else if let dot = text.firstIndex(of: "."), dot > text.startIndex,
      text[..<dot].allSatisfy(\.isNumber)
    {
      text = text[text.index(after: dot)...]
    } else {
      return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }
}
