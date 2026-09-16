import Foundation

/// The slice of the store the controller needs. FlowStore conforms; tests
/// use an in-memory fake.
public protocol DictationStoring: Sendable {
  func insert(_ record: DictationRecord) async throws
}

extension FlowStore: DictationStoring {}

/// Side effects the controller drives, injected as closures so the core loop
/// is fully testable without AppKit. The app wires these to
/// MacOSTextInserter and NSPasteboard.
public struct DictationDependencies: Sendable {
  public var captureTarget: @Sendable () async -> String?
  public var clearTarget: @Sendable () async -> Void
  public var insert: @Sendable (String) async throws -> TextInsertionResult
  public var copyToClipboard: @Sendable (String) async -> Bool

  public init(
    captureTarget: @escaping @Sendable () async -> String?,
    clearTarget: @escaping @Sendable () async -> Void,
    insert: @escaping @Sendable (String) async throws -> TextInsertionResult,
    copyToClipboard: @escaping @Sendable (String) async -> Bool
  ) {
    self.captureTarget = captureTarget
    self.clearTarget = clearTarget
    self.insert = insert
    self.copyToClipboard = copyToClipboard
  }
}

/// How a finished dictation landed — what the indicator needs to say
/// "inserted" vs "saved to history, copied to clipboard".
public struct DictationOutcome: Equatable, Sendable {
  public let dictationID: UUID
  public let text: String
  public let engineUsed: EngineID
  public let fallbackOccurred: Bool
  public let insertionMethod: InsertionMethod
  public let wordCount: Int
  public let failureMessage: String?
}

/// Orchestrates one dictation from hotkey to history row. The invariant this
/// actor exists to defend: once a transcript exists, it is never lost — every
/// failure path lands it in history, and every non-secure failure path also
/// lands it on the clipboard.
public actor DictationController {
  private var machine = DictationStateMachine()
  private let engine: any TranscriptionProviding
  private let cleaner: TranscriptCleaner
  private let store: any DictationStoring
  private let scratchDirectory: URL
  private let dependencies: DictationDependencies
  private var cleanupEnabled = true
  private var hints: @Sendable () async -> [String] = { [] }
  private var onStateChange: @Sendable (DictationState) -> Void = { _ in }
  private var onOutcome: @Sendable (DictationOutcome) -> Void = { _ in }

  public var state: DictationState { machine.state }

  public init(
    engine: any TranscriptionProviding,
    cleaner: TranscriptCleaner,
    store: any DictationStoring,
    scratchDirectory: URL,
    dependencies: DictationDependencies
  ) {
    self.engine = engine
    self.cleaner = cleaner
    self.store = store
    self.scratchDirectory = scratchDirectory
    self.dependencies = dependencies
  }

  public func setCleanupEnabled(_ enabled: Bool) {
    cleanupEnabled = enabled
  }

  public func setHintsProvider(_ provider: @escaping @Sendable () async -> [String]) {
    hints = provider
  }

  /// Observer for the indicator; called on every state transition.
  public func setStateObserver(_ observer: @escaping @Sendable (DictationState) -> Void) {
    onStateChange = observer
    observer(machine.state)
  }

  /// Observer for finished dictations; called once per stored record.
  public func setOutcomeObserver(_ observer: @escaping @Sendable (DictationOutcome) -> Void) {
    onOutcome = observer
  }

  /// Warm the engine so the first hotkey press pays no initialization cost.
  public func prewarm() async {
    await engine.prewarm()
  }

  /// Begin a dictation: capture the destination, enter recording. Returns
  /// false when a dictation is already in flight.
  public func startDictation(mode: DictationMode) async -> Bool {
    if case .recording = machine.state { return false }
    if machine.state == .processing || machine.state == .inserting { return false }
    resetIfTerminal()
    let target = await dependencies.captureTarget()
    do {
      try machine.apply(.start(targetApplication: target, mode: mode))
    } catch {
      return false
    }
    onStateChange(machine.state)
    return true
  }

  public func updateAudioLevel(_ level: Float) {
    try? machine.apply(.updateAudioLevel(level))
  }

  public func cancelDictation() async {
    switch machine.state {
    case .recording, .processing:
      try? machine.apply(.cancel)
      onStateChange(machine.state)
      await dependencies.clearTarget()
    default:
      break
    }
  }

  /// Key-up: transcribe the captured frames, clean, insert, record. The
  /// frames live only for the duration of this call; the temp WAV is removed
  /// on every path out.
  public func finishRecording(frames: [AudioFrame]) async {
    guard case .recording = machine.state else { return }
    let session = machine.session
    try? machine.apply(.stop)
    onStateChange(machine.state)

    let startedProcessing = ContinuousClock.now

    guard frames.contains(where: { !$0.samples.isEmpty }) else {
      await failDictation("No audio captured")
      return
    }

    // Encode to a scratch WAV; audio never outlives this dictation.
    let wavURL = scratchDirectory.appendingPathComponent(
      "dictation-\(UUID().uuidString).wav", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: wavURL) }
    let engineOutcome: EngineOutcome
    do {
      try FileManager.default.createDirectory(
        at: scratchDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let wav = WaveEncoder().encode(frames, outputSampleRate: 16_000)
      try wav.write(to: wavURL, options: .atomic)
      engineOutcome = try await engine.transcribe(audio: wavURL, hints: await hints())
    } catch {
      await failDictation("Transcription failed: \(error)")
      return
    }
    let transcription = engineOutcome.result

    let cleaned = cleaner.clean(transcription.text, enabled: cleanupEnabled)
    let text = cleaned.text
    guard !text.isEmpty else {
      await failDictation("Nothing recognized")
      return
    }
    try? machine.apply(.finish(text))
    onStateChange(machine.state)

    // Insert — and no matter what happens now, the text reaches history.
    var insertionMethod: InsertionMethod
    var failureMessage: String?
    do {
      switch try await dependencies.insert(text) {
      case .inserted, .replacedSelection, .pastedFromClipboard:
        insertionMethod = .ax
      case .copiedToClipboard:
        insertionMethod = .clipboard
      case .noFocusedField:
        // The inserter already copied the text; record the recovery route.
        insertionMethod = .historyOnly
      case .blockedSecureField:
        // History only — deliberately no clipboard copy for password fields.
        insertionMethod = .historyOnly
        failureMessage = "Blocked: the focused field is a password field"
      }
    } catch {
      insertionMethod = .historyOnly
      if await dependencies.copyToClipboard(text) {
        failureMessage = "Saved to history and copied to clipboard"
      } else {
        failureMessage = "Saved to history; clipboard unavailable"
      }
    }

    let processingMs = Int(
      (ContinuousClock.now - startedProcessing) / .milliseconds(1))
    let record = DictationRecord(
      timestamp: session?.startedAt ?? Date(),
      rawTranscript: transcription.text,
      cleanedText: text,
      finalText: text,
      engineUsed: engineOutcome.engineUsed.rawValue,
      fallbackOccurred: engineOutcome.fallbackOccurred,
      durationSeconds: transcription.durationSeconds,
      wordCount: text.split(whereSeparator: \.isWhitespace).count,
      targetApp: session?.targetApplication,
      insertionMethod: insertionMethod,
      processingMs: processingMs)
    try? await store.insert(record)
    onOutcome(
      DictationOutcome(
        dictationID: record.id,
        text: text,
        engineUsed: engineOutcome.engineUsed,
        fallbackOccurred: engineOutcome.fallbackOccurred,
        insertionMethod: insertionMethod,
        wordCount: record.wordCount,
        failureMessage: failureMessage))

    if let failureMessage {
      try? machine.apply(.fail(failureMessage))
    } else {
      try? machine.apply(.inserted)
    }
    onStateChange(machine.state)
    await dependencies.clearTarget()
  }

  private func failDictation(_ message: String) async {
    try? machine.apply(.fail(message))
    onStateChange(machine.state)
    await dependencies.clearTarget()
  }

  private func resetIfTerminal() {
    switch machine.state {
    case .completed, .cancelled, .failed:
      try? machine.apply(.reset)
    default:
      break
    }
  }
}
