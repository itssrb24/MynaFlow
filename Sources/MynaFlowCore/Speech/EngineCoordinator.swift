import Foundation

/// A transcription plus which engine actually produced it — what the history
/// record stores.
public struct EngineOutcome: Equatable, Sendable {
  public let result: TranscriptionResult
  public let engineUsed: EngineID
  public let fallbackOccurred: Bool

  public init(result: TranscriptionResult, engineUsed: EngineID, fallbackOccurred: Bool) {
    self.result = result
    self.engineUsed = engineUsed
    self.fallbackOccurred = fallbackOccurred
  }
}

/// What the dictation controller consumes: either a bare engine (via the
/// extension below) or the coordinator with its silent fallback.
public protocol TranscriptionProviding: Sendable {
  func transcribe(audio: URL, hints: [String]) async throws -> EngineOutcome
  func prewarm() async
}

extension SpeechEngine {
  public func transcribe(audio: URL, hints: [String]) async throws -> EngineOutcome {
    EngineOutcome(
      result: try await transcribe(audio: audio, hints: hints) as TranscriptionResult,
      engineUsed: id,
      fallbackOccurred: false)
  }

  public func prewarm() async {
    await prepare()
  }
}

extension AppleSpeechEngine: TranscriptionProviding {}

/// Engine selection + the silent fallback rule: if the preferred engine fails
/// for any reason, complete the dictation through the fallback and record
/// that it happened. The user finds out after the fact, never mid-flow.
public struct EngineCoordinator: TranscriptionProviding {
  private let primary: any SpeechEngine
  private let fallback: any SpeechEngine

  public init(primary: any SpeechEngine, fallback: any SpeechEngine) {
    self.primary = primary
    self.fallback = fallback
  }

  public func prewarm() async {
    // Warm the engine that will actually serve the next dictation.
    if primary.id != fallback.id, await primary.isAvailable {
      await primary.prepare()
    } else {
      await fallback.prepare()
    }
  }

  public func transcribe(audio: URL, hints: [String]) async throws -> EngineOutcome {
    // An uninstalled primary is a configuration state, not a failure.
    guard primary.id != fallback.id, await primary.isAvailable else {
      let result: TranscriptionResult = try await fallback.transcribe(audio: audio, hints: hints)
      return EngineOutcome(result: result, engineUsed: fallback.id, fallbackOccurred: false)
    }
    do {
      let result: TranscriptionResult = try await primary.transcribe(audio: audio, hints: hints)
      return EngineOutcome(result: result, engineUsed: primary.id, fallbackOccurred: false)
    } catch {
      let result: TranscriptionResult = try await fallback.transcribe(audio: audio, hints: hints)
      return EngineOutcome(result: result, engineUsed: fallback.id, fallbackOccurred: true)
    }
  }
}
