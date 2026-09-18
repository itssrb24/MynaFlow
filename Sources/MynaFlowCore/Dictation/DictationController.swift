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
  /// (text, allowBlindPaste) — the second argument carries the target app's
  /// opt-in for pasting into a field Accessibility cannot see.
  public var insert: @Sendable (String, Bool) async throws -> TextInsertionResult
  public var copyToClipboard: @Sendable (String) async -> Bool
  /// The inserter's explanation of the last attempt; recorded on fallbacks.
  public var insertionDiagnostics: @Sendable () async -> String?

  public init(
    captureTarget: @escaping @Sendable () async -> String?,
    clearTarget: @escaping @Sendable () async -> Void,
    insert: @escaping @Sendable (String, Bool) async throws -> TextInsertionResult,
    copyToClipboard: @escaping @Sendable (String) async -> Bool,
    insertionDiagnostics: @escaping @Sendable () async -> String? = { nil }
  ) {
    self.captureTarget = captureTarget
    self.clearTarget = clearTarget
    self.insert = insert
    self.copyToClipboard = copyToClipboard
    self.insertionDiagnostics = insertionDiagnostics
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

/// One ordered channel for everything the UI needs to know. Delivering the
/// outcome and the terminal state as separate callbacks let two independent
/// main-actor hops race, so the success pill could read a stale outcome.
public enum DictationControllerEvent: Equatable, Sendable {
  case state(DictationState)
  /// Always delivered before the `.completed`/`.failed` state that ends it.
  case outcome(DictationOutcome)
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
  /// Whether the cleaner adds a terminal period. One setting for every app.
  private var terminalPeriod = true
  /// Paste even when Accessibility cannot see the focused field. Canvas
  /// editors such as Google Docs expose no text element at all, so without
  /// this nothing ever reaches them.
  private var pasteWhenUnseen = true
  /// Rewrites text in the style with this id; nil means "leave it alone"
  /// (model missing, timed out, or failed) — the cleaned text is inserted.
  private var polisher: @Sendable (UUID, String) async -> (text: String, styleName: String)? = { _, _ in nil }
  private var onEvent: @Sendable (DictationControllerEvent) -> Void = { _ in }
  private func onStateChange(_ state: DictationState) { onEvent(.state(state)) }
  private func onOutcome(_ outcome: DictationOutcome) { onEvent(.outcome(outcome)) }

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

  public func setTerminalPeriod(_ enabled: Bool) {
    terminalPeriod = enabled
  }

  public func setPasteWhenUnseen(_ enabled: Bool) {
    pasteWhenUnseen = enabled
  }

  public func setPolisher(
    _ polisher: @escaping @Sendable (UUID, String) async -> (text: String, styleName: String)?
  ) {
    self.polisher = polisher
  }

  /// Single ordered observer for state transitions and outcomes. Called
  /// synchronously on the actor in the order things happened; the consumer
  /// must preserve that order (e.g. a single serial task).
  public func setEventObserver(_ observer: @escaping @Sendable (DictationControllerEvent) -> Void) {
    onEvent = observer
    observer(.state(machine.state))
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

  /// Key-up with in-memory frames (tests, small captures): encodes to a
  /// scratch WAV and continues as `finishRecording(audio:)`.
  public func finishRecording(frames: [AudioFrame]) async {
    guard case .recording = machine.state else { return }
    guard frames.contains(where: { !$0.samples.isEmpty }) else {
      try? machine.apply(.stop)
      onStateChange(machine.state)
      await failDictation("No audio captured")
      return
    }
    let wavURL = scratchDirectory.appendingPathComponent(
      "dictation-\(UUID().uuidString).wav", isDirectory: false)
    do {
      try FileManager.default.createDirectory(
        at: scratchDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let wav = WaveEncoder().encode(frames, outputSampleRate: 16_000)
      // Created with its mode rather than chmod'd after: recorded audio must
      // never exist world-readable, not even briefly.
      guard FileManager.default.createFile(
        atPath: wavURL.path, contents: wav, attributes: [.posixPermissions: 0o600])
      else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: wavURL.path]) }
    } catch {
      try? machine.apply(.stop)
      onStateChange(machine.state)
      await failDictation("Could not write audio: \(error)")
      return
    }
    await finishRecording(audio: wavURL, hasAudio: true)
  }

  /// Key-up: transcribe the scratch WAV (streamed to disk during capture),
  /// clean, insert, record. The WAV is removed on every path out; audio
  /// never outlives this dictation.
  public func finishRecording(audio wavURL: URL, hasAudio: Bool) async {
    guard case .recording = machine.state else {
      try? FileManager.default.removeItem(at: wavURL)
      return
    }
    let session = machine.session
    try? machine.apply(.stop)
    onStateChange(machine.state)

    let startedProcessing = ContinuousClock.now
    defer { try? FileManager.default.removeItem(at: wavURL) }

    guard hasAudio else {
      await failDictation("No audio captured")
      return
    }

    let engineOutcome: EngineOutcome
    do {
      engineOutcome = try await engine.transcribe(audio: wavURL, hints: await hints())
    } catch {
      await failDictation("Transcription failed: \(error)")
      return
    }
    let transcription = engineOutcome.result

    let cleaned = cleaner.clean(
      transcription.text,
      enabled: cleanupEnabled,
      terminalPunctuation: terminalPeriod)
    var text = cleaned.text
    guard !text.isEmpty else {
      await failDictation("Nothing recognized")
      return
    }
    // Polishing is always something the user asks for, by hotkey or button;
    // a dictation is never rewritten on its own.
    let styleApplied: String? = nil
    // The actor was suspended during transcription; a cancel may have landed
    // meanwhile. A cancelled dictation must produce no side effects at all.
    do {
      try machine.apply(.finish(text))
    } catch {
      return
    }
    onStateChange(machine.state)

    // Insert — and no matter what happens now, the text reaches history.
    var insertionMethod: InsertionMethod
    var failureMessage: String?
    var blockedBySecureField = false
    var onClipboard = false
    do {
      switch try await dependencies.insert(text, pasteWhenUnseen) {
      case .inserted, .replacedSelection, .pastedFromClipboard:
        insertionMethod = .ax
      case .copiedToClipboard:
        insertionMethod = .clipboard
        onClipboard = true
      case .noFocusedField:
        // The inserter already copied the text; record the recovery route.
        insertionMethod = .historyOnly
        onClipboard = true
      case .blockedSecureField:
        // History only — deliberately no clipboard copy for password fields.
        insertionMethod = .historyOnly
        blockedBySecureField = true
        failureMessage = "Blocked: the focused field is a password field"
      }
    } catch {
      insertionMethod = .historyOnly
      if await dependencies.copyToClipboard(text) {
        onClipboard = true
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
      cleanedText: cleaned.text,
      finalText: text,
      styleApplied: styleApplied,
      engineUsed: engineOutcome.engineUsed.rawValue,
      fallbackOccurred: engineOutcome.fallbackOccurred,
      durationSeconds: transcription.durationSeconds,
      wordCount: text.split(whereSeparator: \.isWhitespace).count,
      targetApp: session?.targetApplication,
      insertionMethod: insertionMethod,
      processingMs: processingMs,
      insertionDiagnostics: insertionMethod == .ax ? nil : await dependencies.insertionDiagnostics())
    do {
      try await store.insert(record)
    } catch {
      // The one place the never-lose-text invariant could break: keep the
      // text on the clipboard and say so, instead of reporting success.
      // Password-field blocks stay off the pasteboard even now.
      if blockedBySecureField {
        failureMessage = "Blocked: password field — and history could not be saved (\(error))"
      } else {
        if !onClipboard, await dependencies.copyToClipboard(text) { onClipboard = true }
        failureMessage =
          onClipboard
          ? "Could not save to history (\(error)) — text is on the clipboard"
          : "Could not save to history (\(error))"
      }
    }
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
