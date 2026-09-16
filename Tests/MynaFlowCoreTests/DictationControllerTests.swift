import Foundation
import Testing

@testable import MynaFlowCore

// MARK: - Fakes

private struct FakeEngine: SpeechEngine {
  let id: EngineID = .apple
  var result: Result<String, SpeechEngineError> = .success("um hello there")
  var isAvailable: Bool { get async { true } }
  func prepare() async {}
  func transcribe(audio: URL, hints: [String]) async throws -> TranscriptionResult {
    switch result {
    case .success(let text): return TranscriptionResult(text: text, durationSeconds: 2.0)
    case .failure(let error): throw error
    }
  }
}

private actor FakeStore: DictationStoring {
  private(set) var records: [DictationRecord] = []
  func insert(_ record: DictationRecord) async throws {
    records.append(record)
  }
}

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _insertedTexts: [String] = []
  private var _clipboardTexts: [String] = []
  private var _clearedTarget = false

  func recordInsert(_ text: String) {
    lock.lock()
    _insertedTexts.append(text)
    lock.unlock()
  }
  func recordClipboard(_ text: String) {
    lock.lock()
    _clipboardTexts.append(text)
    lock.unlock()
  }
  func recordClear() {
    lock.lock()
    _clearedTarget = true
    lock.unlock()
  }
  var insertedTexts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _insertedTexts
  }
  var clipboardTexts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _clipboardTexts
  }
  var clearedTarget: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _clearedTarget
  }
}

private func makeController(
  engine: FakeEngine = FakeEngine(),
  store: FakeStore,
  recorder: Recorder,
  insertOutcome: @escaping @Sendable (String) throws -> TextInsertionResult = { _ in .inserted }
) -> DictationController {
  let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("flow-controller-tests-\(UUID().uuidString)", isDirectory: true)
  return DictationController(
    engine: engine,
    cleaner: TranscriptCleaner(),
    store: store,
    scratchDirectory: scratch,
    dependencies: DictationDependencies(
      captureTarget: { "com.apple.TextEdit" },
      clearTarget: { recorder.recordClear() },
      insert: { text in
        recorder.recordInsert(text)
        return try insertOutcome(text)
      },
      copyToClipboard: { text in
        recorder.recordClipboard(text)
        return true
      }))
}

private func someFrames() -> [AudioFrame] {
  [AudioFrame(samples: [Float](repeating: 0.1, count: 1_600), sampleRate: 16_000)]
}

private final class OutcomeCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var outcomes: [DictationOutcome] = []
  func append(_ outcome: DictationOutcome) {
    lock.lock()
    outcomes.append(outcome)
    lock.unlock()
  }
  var all: [DictationOutcome] {
    lock.lock()
    defer { lock.unlock() }
    return outcomes
  }
}

// MARK: - Tests

@Suite("DictationController")
struct DictationControllerTests {
  @Test("Happy path: transcript is cleaned, inserted, and stored with ax method")
  func happyPath() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(store: store, recorder: recorder)

    let started = await controller.startDictation(mode: .hold)
    #expect(started)
    await controller.finishRecording(frames: someFrames())

    #expect(recorder.insertedTexts == ["Hello there."])
    let records = await store.records
    let record = try #require(records.first)
    #expect(record.rawTranscript == "um hello there")
    #expect(record.cleanedText == "Hello there.")
    #expect(record.finalText == "Hello there.")
    #expect(record.engineUsed == "apple")
    #expect(record.insertionMethod == .ax)
    #expect(record.targetApp == "com.apple.TextEdit")
    #expect(record.wordCount == 2)
    #expect(record.processingMs >= 0)
    let state = await controller.state
    #expect(state == .completed)
    #expect(recorder.clearedTarget)
  }

  @Test("Insertion throwing still writes history and copies to clipboard")
  func insertionFailureKeepsText() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(
      store: store, recorder: recorder,
      insertOutcome: { _ in throw SpeechEngineError("AX exploded") })

    _ = await controller.startDictation(mode: .hold)
    await controller.finishRecording(frames: someFrames())

    #expect(recorder.clipboardTexts == ["Hello there."])
    let records = await store.records
    let record = try #require(records.first)
    #expect(record.insertionMethod == .historyOnly)
    let state = await controller.state
    #expect(state == .failed(message: "Saved to history and copied to clipboard"))
  }

  @Test("No focused field routes to history + clipboard with the distinct method")
  func noFocusedField() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(
      store: store, recorder: recorder, insertOutcome: { _ in .noFocusedField })

    _ = await controller.startDictation(mode: .hold)
    await controller.finishRecording(frames: someFrames())

    let records = await store.records
    #expect(try #require(records.first).insertionMethod == .historyOnly)
    let state = await controller.state
    #expect(state == .completed)
  }

  @Test("Clipboard-paste and copied results map to their insertion methods")
  func insertionMethodMapping() async throws {
    for (outcome, expected) in [
      (TextInsertionResult.pastedFromClipboard, InsertionMethod.ax),
      (.replacedSelection, .ax),
      (.copiedToClipboard, .clipboard),
    ] {
      let store = FakeStore()
      let recorder = Recorder()
      let controller = makeController(
        store: store, recorder: recorder, insertOutcome: { _ in outcome })
      _ = await controller.startDictation(mode: .hold)
      await controller.finishRecording(frames: someFrames())
      let records = await store.records
      #expect(try #require(records.first).insertionMethod == expected)
    }
  }

  @Test("Secure field block writes history but never touches the clipboard")
  func secureFieldBlock() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(
      store: store, recorder: recorder, insertOutcome: { _ in .blockedSecureField })

    _ = await controller.startDictation(mode: .hold)
    await controller.finishRecording(frames: someFrames())

    #expect(recorder.clipboardTexts.isEmpty, "secure fields must never leak to the pasteboard")
    let records = await store.records
    #expect(try #require(records.first).insertionMethod == .historyOnly)
  }

  @Test("Engine failure ends in failed state with no history row")
  func engineFailure() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    var engine = FakeEngine()
    engine.result = .failure(SpeechEngineError("nothing recognized"))
    let controller = makeController(engine: engine, store: store, recorder: recorder)

    _ = await controller.startDictation(mode: .hold)
    await controller.finishRecording(frames: someFrames())

    #expect(recorder.insertedTexts.isEmpty)
    let records = await store.records
    #expect(records.isEmpty)
    let state = await controller.state
    guard case .failed = state else {
      Issue.record("expected failed state, got \(state)")
      return
    }
  }

  @Test("Cancel discards everything")
  func cancel() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(store: store, recorder: recorder)

    _ = await controller.startDictation(mode: .hold)
    await controller.cancelDictation()

    let records = await store.records
    #expect(records.isEmpty)
    #expect(recorder.insertedTexts.isEmpty)
    let state = await controller.state
    #expect(state == .cancelled)
  }

  @Test("Scratch WAV is deleted on success and on engine failure")
  func scratchCleanup() async throws {
    for failing in [false, true] {
      let store = FakeStore()
      let recorder = Recorder()
      var engine = FakeEngine()
      if failing { engine.result = .failure(SpeechEngineError("boom")) }
      let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("flow-scratch-\(UUID().uuidString)", isDirectory: true)
      let controller = DictationController(
        engine: engine,
        cleaner: TranscriptCleaner(),
        store: store,
        scratchDirectory: scratch,
        dependencies: DictationDependencies(
          captureTarget: { nil },
          clearTarget: {},
          insert: { _ in .inserted },
          copyToClipboard: { _ in true }))
      _ = await controller.startDictation(mode: .hold)
      await controller.finishRecording(frames: someFrames())
      let leftovers =
        (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
      #expect(leftovers.isEmpty, "scratch must be empty (failing=\(failing)): \(leftovers)")
    }
  }

  @Test("A second dictation can start after the first completes")
  func restart() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(store: store, recorder: recorder)

    _ = await controller.startDictation(mode: .hold)
    await controller.finishRecording(frames: someFrames())
    let restarted = await controller.startDictation(mode: .toggle)
    #expect(restarted)
    await controller.finishRecording(frames: someFrames())
    let records = await store.records
    #expect(records.count == 2)
  }

  @Test("Outcome observer reports the insertion method and word count")
  func outcomeObserver() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(
      store: store, recorder: recorder, insertOutcome: { _ in .noFocusedField })
    let outcomes = OutcomeCollector()
    await controller.setOutcomeObserver { outcome in
      outcomes.append(outcome)
    }
    _ = await controller.startDictation(mode: .hold)
    await controller.finishRecording(frames: someFrames())
    let collected = outcomes.all
    #expect(collected.count == 1)
    let outcome = try #require(collected.first)
    #expect(outcome.insertionMethod == .historyOnly)
    #expect(outcome.wordCount == 2)
    #expect(outcome.failureMessage == nil)
  }

  @Test("Empty audio fails cleanly without a history row")
  func emptyAudio() async throws {
    let store = FakeStore()
    let recorder = Recorder()
    let controller = makeController(store: store, recorder: recorder)
    _ = await controller.startDictation(mode: .hold)
    await controller.finishRecording(frames: [])
    let records = await store.records
    #expect(records.isEmpty)
    let state = await controller.state
    guard case .failed = state else {
      Issue.record("expected failed state, got \(state)")
      return
    }
  }
}
