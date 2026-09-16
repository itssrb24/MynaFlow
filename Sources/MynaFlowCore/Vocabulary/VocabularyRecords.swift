import Foundation

public enum VocabularySource: String, Codable, Equatable, Sendable {
  case manual
  /// Approved from the corrections review queue.
  case promoted
}

public struct VocabularyTerm: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let term: String
  public let addedAt: Date
  public let source: VocabularySource
}

public enum CorrectionStatus: String, Codable, Equatable, Sendable {
  case candidate
  case accepted
  case dismissed
}

public struct CorrectionRecord: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let dictationID: UUID?
  public let pair: CorrectionPair
  public let observedAt: Date
  public let status: CorrectionStatus
}
