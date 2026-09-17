import Foundation

/// How the final text reached the user. `historyOnly` is the "dictated at the
/// wrong moment" recovery: no focused field, so history + clipboard.
public enum InsertionMethod: String, Codable, Equatable, Sendable {
  case ax
  case clipboard
  case historyOnly = "history_only"
}

public struct DictationRecord: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let rawTranscript: String
  public let cleanedText: String
  public var finalText: String
  public var styleApplied: String?
  public let engineUsed: String
  public let fallbackOccurred: Bool
  public let durationSeconds: Double
  public let wordCount: Int
  public let targetApp: String?
  public let insertionMethod: InsertionMethod
  public let processingMs: Int
  /// Why insertion fell back (AX role, app, reason); nil when it landed.
  public let insertionDiagnostics: String?

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    rawTranscript: String,
    cleanedText: String,
    finalText: String,
    styleApplied: String? = nil,
    engineUsed: String,
    fallbackOccurred: Bool = false,
    durationSeconds: Double,
    wordCount: Int,
    targetApp: String? = nil,
    insertionMethod: InsertionMethod,
    processingMs: Int,
    insertionDiagnostics: String? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.rawTranscript = rawTranscript
    self.cleanedText = cleanedText
    self.finalText = finalText
    self.styleApplied = styleApplied
    self.engineUsed = engineUsed
    self.fallbackOccurred = fallbackOccurred
    self.durationSeconds = durationSeconds
    self.wordCount = wordCount
    self.targetApp = targetApp
    self.insertionMethod = insertionMethod
    self.processingMs = processingMs
    self.insertionDiagnostics = insertionDiagnostics
  }
}

/// One before/after pair guiding a custom style's rewrites.
public struct StyleExample: Codable, Equatable, Sendable {
  public var input: String
  public var output: String

  public init(input: String, output: String) {
    self.input = input
    self.output = output
  }
}

public struct Style: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var prompt: String
  public let builtin: Bool
  /// 1...5, or nil when the style has no hotkey.
  public var hotkeySlot: Int?
  public var examples: [StyleExample]
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    prompt: String,
    builtin: Bool = false,
    hotkeySlot: Int? = nil,
    examples: [StyleExample] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.prompt = prompt
    self.builtin = builtin
    self.hotkeySlot = hotkeySlot
    self.examples = examples
    self.createdAt = createdAt
  }
}
