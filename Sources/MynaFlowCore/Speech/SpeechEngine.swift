import Foundation

public enum EngineID: String, Codable, Equatable, Sendable {
  case apple
  case parakeet
}

/// The transcription outcome. Deliberately a struct rather than a bare String
/// so a v0.2 streaming experiment can add partial-result fields without
/// touching every engine.
public struct TranscriptionResult: Equatable, Sendable {
  public let text: String
  public let durationSeconds: Double

  public init(text: String, durationSeconds: Double) {
    self.text = text
    self.durationSeconds = durationSeconds
  }
}

public struct SpeechEngineError: Error, Equatable, CustomStringConvertible, Sendable {
  public let message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { "SpeechEngine: \(message)" }
}

/// One speech engine. Adding an engine means one conformance plus a catalog
/// entry — nothing else changes.
public protocol SpeechEngine: Sendable {
  var id: EngineID { get }
  /// Whether the engine can transcribe right now (models installed, etc.).
  var isAvailable: Bool { get async }
  /// Warm up so the first hotkey press pays no initialization cost.
  func prepare() async
  /// Transcribe a WAV on disk. Throws when nothing was recognized or the
  /// engine failed; the coordinator turns that into a silent fallback.
  func transcribe(audio: URL, hints: [String]) async throws -> TranscriptionResult
}
