import Foundation

public enum MeetingSummaryOutcome: Equatable, Sendable {
  case summarized(MeetingSummary)
  /// No summary was attempted; the string says why, for the user.
  case unavailable(String)
  case failed(String)
}

/// Summarizes a meeting with the local Gemma model, map-reduce style: each
/// transcript part becomes notes, then the notes are merged once. A model
/// never sees more than one part at a time, so a long meeting fits a small
/// context window.
public struct MeetingSummarizer: Sendable {
  public static let noModelNote =
    "No summary: no language model is installed. Install one in Models to summarize meetings."
  public static let emptyNote = "No summary: nothing was transcribed."

  private let model: (any LocalLanguageModel)?
  private let maxPartCharacters: Int

  public init(model: (any LocalLanguageModel)?, maxPartCharacters: Int = 6_000) {
    self.model = model
    self.maxPartCharacters = maxPartCharacters
  }

  public func summarize(_ segments: [MeetingSegment]) async -> MeetingSummaryOutcome {
    guard let model else { return .unavailable(Self.noModelNote) }
    let parts = Self.split(segments, maxCharacters: maxPartCharacters)
    guard !parts.isEmpty else { return .unavailable(Self.emptyNote) }
    do {
      var notes: [String] = []
      for part in parts {
        notes.append(try await model.generateInstruction(Self.mapPrompt(part), maxTokens: 768))
      }
      let final =
        notes.count == 1
        ? notes[0]
        : try await model.generateInstruction(Self.reducePrompt(notes), maxTokens: 1_024)
      guard let summary = Self.parse(final) else {
        return .failed("The model's summary could not be read.")
      }
      return .summarized(summary)
    } catch {
      // Type only: an error may carry model output, which is the user's words.
      return .failed("Summary failed (\(type(of: error))).")
    }
  }

  // MARK: - Prompts

  private static let format = """
    Reply in exactly this format and nothing else:
    KEY POINTS:
    - <point>
    ACTION ITEMS:
    - <owner if stated>: <task>
    Write "- None" under a heading with nothing to list.
    """

  static func mapPrompt(_ transcriptPart: String) -> String {
    """
    Below is part of a meeting transcript. "You" is the person taking notes; \
    "Others" is everyone else on the call. Extract the key points (decisions, \
    facts, open questions) and the action items.

    \(format)

    Transcript:
    \(transcriptPart)
    """
  }

  static func reducePrompt(_ notes: [String]) -> String {
    let rendered = notes.enumerated()
      .map { "Notes from part \($0.offset + 1):\n\($0.element)" }
      .joined(separator: "\n\n")
    return """
      These are notes from consecutive parts of one meeting. Merge them into a \
      single summary: combine duplicates, keep every distinct decision and task.

      \(format)

      \(rendered)
      """
  }

  /// Packs whole transcript lines into parts of at most `maxCharacters`. A
  /// single over-long line becomes its own part rather than being cut.
  static func split(_ segments: [MeetingSegment], maxCharacters: Int) -> [String] {
    var parts: [String] = []
    var current = ""
    for segment in segments where !segment.text.isEmpty {
      let line = MeetingTranscript.line(segment)
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

  private enum Section { case keyPoints, actionItems }

  /// Reads the two headed bullet lists, tolerating Markdown decoration.
  /// Nil when neither heading is present — prose is not a summary.
  static func parse(_ output: String) -> MeetingSummary? {
    var section: Section?
    var sawHeading = false
    var keyPoints: [String] = []
    var actionItems: [String] = []
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let heading = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
      if heading == "key points" {
        section = .keyPoints
        sawHeading = true
        continue
      }
      if heading == "action items" {
        section = .actionItems
        sawHeading = true
        continue
      }
      guard let section, let item = bulletText(line) else { continue }
      if item.lowercased().trimmingCharacters(in: .punctuationCharacters) == "none" { continue }
      switch section {
      case .keyPoints: keyPoints.append(item)
      case .actionItems: actionItems.append(item)
      }
    }
    return sawHeading ? MeetingSummary(keyPoints: keyPoints, actionItems: actionItems) : nil
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
