import Foundation

/// How the user activated dictation. Toggle sessions get a visually distinct
/// indicator and an auto-stop safety valve; hold sessions end on key-up.
public enum DictationMode: String, Codable, Equatable, Sendable {
  case hold
  case toggle
}

public struct DictationSession: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let startedAt: Date
  public var endedAt: Date?
  public var audioLevel: Float
  public var interimTranscript: String
  public var finalTranscript: String?
  public let targetApplication: String?
  public let mode: DictationMode
  public var wasCancelled: Bool

  public init(
    id: UUID = UUID(),
    startedAt: Date = Date(),
    endedAt: Date? = nil,
    audioLevel: Float = 0,
    interimTranscript: String = "",
    finalTranscript: String? = nil,
    targetApplication: String? = nil,
    mode: DictationMode = .hold,
    wasCancelled: Bool = false
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.audioLevel = audioLevel
    self.interimTranscript = interimTranscript
    self.finalTranscript = finalTranscript
    self.targetApplication = targetApplication
    self.mode = mode
    self.wasCancelled = wasCancelled
  }
}

public enum DictationState: Equatable, Sendable {
  case idle
  case recording(targetApplication: String?)
  case processing
  /// Transcript is final; the inserter is placing it at the cursor. Failure
  /// here keeps the transcript on the session so it can never be lost.
  case inserting
  case completed
  case cancelled
  case failed(message: String)
}

public enum DictationEvent: Equatable, Sendable {
  case start(targetApplication: String?, mode: DictationMode)
  case updateAudioLevel(Float)
  case updateInterim(String)
  case stop
  case finish(String)
  case inserted
  case cancel
  case fail(String)
  case reset
}

public struct DictationTransitionError: Error, Equatable, CustomStringConvertible, Sendable {
  public let state: DictationState
  public let event: DictationEvent

  public var description: String { "Invalid dictation transition from \(state) using \(event)" }
}

public struct DictationStateMachine: Sendable {
  public private(set) var state: DictationState = .idle
  public private(set) var session: DictationSession?

  public init() {}

  public mutating func apply(_ event: DictationEvent, now: Date = Date()) throws {
    switch (state, event) {
    case (.idle, .start(let target, let mode)),
      (.completed, .start(let target, let mode)),
      (.cancelled, .start(let target, let mode)),
      (.failed, .start(let target, let mode)):
      session = DictationSession(startedAt: now, targetApplication: target, mode: mode)
      state = .recording(targetApplication: target)

    case (.recording, .updateAudioLevel(let level)):
      session?.audioLevel = min(max(level, 0), 1)

    case (.recording, .updateInterim(let transcript)):
      session?.interimTranscript = transcript

    case (.recording, .stop):
      session?.endedAt = now
      session?.audioLevel = 0
      state = .processing

    case (.processing, .finish(let transcript)):
      session?.finalTranscript = transcript
      if session?.endedAt == nil {
        session?.endedAt = now
      }
      state = .inserting

    case (.inserting, .inserted):
      state = .completed

    case (.recording, .cancel), (.processing, .cancel):
      session?.interimTranscript = ""
      session?.finalTranscript = nil
      session?.audioLevel = 0
      session?.endedAt = now
      session?.wasCancelled = true
      state = .cancelled

    case (.recording, .fail(let message)), (.processing, .fail(let message)),
      (.inserting, .fail(let message)):
      session?.audioLevel = 0
      if session?.endedAt == nil {
        session?.endedAt = now
      }
      state = .failed(message: message)

    case (.completed, .reset), (.cancelled, .reset), (.failed, .reset):
      session = nil
      state = .idle

    default:
      throw DictationTransitionError(state: state, event: event)
    }
  }
}
