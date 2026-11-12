import Foundation
import Testing

@testable import MynaFlowCore

// MARK: - Fakes

/// Transcribes a chunk as "<channel>#<index>" read from its file name, so the
/// result is deterministic whatever order chunks are processed in. Records
/// whether each file still existed when handed over.
private actor ChunkNamingTranscriber: TranscriptionProviding {
  private(set) var seen: [String] = []
  var failingChunkNames: Set<String> = []
  var quietChunkNames: Set<String> = []
  var punctuationChunkNames: Set<String> = []
  var hook: (@Sendable () async -> Void)?

  func setFailing(_ names: Set<String>) { failingChunkNames = names }
  func setQuiet(_ names: Set<String>) { quietChunkNames = names }
  func setPunctuationOnly(_ names: Set<String>) { punctuationChunkNames = names }
  func setHook(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }

  func prewarm() async {}

  func transcribe(audio: URL, hints: [String]) async throws -> EngineOutcome {
    let name = audio.deletingPathExtension().lastPathComponent
    seen.append(name)
    #expect(FileManager.default.fileExists(atPath: audio.path))
    if let hook { await hook() }
    if failingChunkNames.contains(where: { name.hasSuffix($0) }) {
      throw SpeechEngineError("engine crashed")
    }
    if quietChunkNames.contains(where: { name.hasSuffix($0) }) {
      throw SpeechEngineError.nothingRecognized
    }
    if punctuationChunkNames.contains(where: { name.hasSuffix($0) }) {
      return EngineOutcome(
        result: TranscriptionResult(text: " . ", durationSeconds: 1),
        engineUsed: .parakeet, fallbackOccurred: false)
    }
    // meeting-<uuid>-<channel>-<index>
    let parts = name.split(separator: "-")
    let label = "\(parts[parts.count - 2])#\(parts[parts.count - 1])"
    return EngineOutcome(
      result: TranscriptionResult(text: label, durationSeconds: 1),
      engineUsed: .parakeet, fallbackOccurred: false)
  }
}

private actor FakeMeetingStore: MeetingStoring {
  private(set) var meetings: [MeetingRecord] = []
  var failInsert = false
  func setFailInsert(_ value: Bool) { failInsert = value }
  func insertMeeting(_ record: MeetingRecord) async throws {
    if failInsert { throw FlowStoreError(message: "disk full") }
    meetings.append(record)
  }
}

// MARK: - Helpers

private let rate = 16_000.0

/// `seconds` of a quiet tone at 16 kHz, so the writer does no resampling.
private func frame(seconds: Double) -> AudioFrame {
  AudioFrame(samples: Array(repeating: 0.01, count: Int(seconds * rate)), sampleRate: rate)
}

private func makeScratch() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("meeting-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func audioFiles(in directory: URL) -> [String] {
  ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    .filter { $0.hasSuffix(".wav") }
}

private func makeSession(
  transcriber: ChunkNamingTranscriber,
  store: FakeMeetingStore,
  scratch: URL,
  model: (any LocalLanguageModel)? = nil
) -> MeetingSession {
  MeetingSession(
    transcriber: transcriber,
    summarizer: MeetingSummarizer(model: model),
    store: store,
    scratchDirectory: scratch,
    chunkSeconds: 1,
    now: { Date(timeIntervalSince1970: 1_800_000_000) })
}

// MARK: - Tests

@Suite("MeetingSession")
struct MeetingSessionTests {
  @Test("rotates each channel into a new chunk every chunkSeconds")
  func rotatesChunks() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    // 2.5 s of mic in half-second frames → chunks 0 and 1 rotate, 2 is partial.
    for _ in 0..<5 { await session.append(frame(seconds: 0.5), channel: .you) }
    #expect(await session.completedChunkCount(for: .you) == 2)
    #expect(await session.completedChunkCount(for: .others) == 0)

    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["you#0", "you#1", "you#2"])
    #expect(record.segments.map(\.startSeconds) == [0, 1, 2])
    #expect(record.durationSeconds == 2.5)
  }

  @Test("every chunk is deleted after transcription — none remain after stop")
  func deletesChunksAfterTranscription() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    for _ in 0..<3 {
      await session.append(frame(seconds: 1), channel: .you)
      await session.append(frame(seconds: 1), channel: .others)
    }
    _ = await session.stop()
    #expect(audioFiles(in: scratch).isEmpty)
    #expect(await transcriber.seen.count == 6)
  }

  @Test("a chunk the engine fails on is skipped and still deleted")
  func failedChunkIsDeleted() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    await transcriber.setFailing(["you-1"])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    for _ in 0..<3 { await session.append(frame(seconds: 1), channel: .you) }
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["you#0", "you#2"])
    #expect(audioFiles(in: scratch).isEmpty)
    // The gap is never silent: the saved note says audio went untranscribed.
    #expect(record.summaryNote?.contains("1 part of the audio could not be transcribed") == true)
  }

  @Test("room noise the engine recognizes nothing in is not reported as a gap")
  func nothingRecognizedIsNotAGap() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    await transcriber.setQuiet(["you-1"])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    for _ in 0..<3 { await session.append(frame(seconds: 1), channel: .you) }
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["you#0", "you#2"])
    #expect(record.summaryNote == MeetingSummarizer.noModelNote)
    #expect(audioFiles(in: scratch).isEmpty)
  }

  @Test("a chunk transcribed as punctuation only adds no segment")
  func punctuationOnlyDropped() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    await transcriber.setPunctuationOnly(["you-1"])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    for _ in 0..<3 { await session.append(frame(seconds: 1), channel: .you) }
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["you#0", "you#2"])
    #expect(record.summaryNote == MeetingSummarizer.noModelNote)
  }

  @Test("a silent chunk is deleted without transcription and is not reported as a gap")
  func silentChunkSkipped() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    await session.append(frame(seconds: 1), channel: .you)
    await session.append(
      AudioFrame(samples: Array(repeating: 0, count: Int(rate)), sampleRate: rate), channel: .others)
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(await transcriber.seen.count == 1)
    #expect(record.summaryNote == MeetingSummarizer.noModelNote)
    #expect(audioFiles(in: scratch).isEmpty)
  }

  @Test("a meeting started for a calendar event is saved with its title")
  func savesEventTitle() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start(title: "Weekly sync")
    await session.append(frame(seconds: 1), channel: .you)
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.eventTitle == "Weekly sync")
  }

  @Test("a second concurrent stop does not save the meeting twice")
  func doubleStopSavesOnce() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    await session.append(frame(seconds: 1.5), channel: .you)
    async let first = session.stop()
    async let second = session.stop()
    let results = await [first, second]

    #expect(results.filter { if case .saved = $0 { true } else { false } }.count == 1)
    #expect(results.contains(.notRecording))
    #expect(await store.meetings.count == 1)
  }

  @Test("cancel deletes completed, in-flight and partial chunks and saves nothing")
  func cancelDeletesEverything() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    for _ in 0..<4 { await session.append(frame(seconds: 0.75), channel: .others) }
    await session.append(frame(seconds: 0.3), channel: .you)
    await session.cancel()

    #expect(audioFiles(in: scratch).isEmpty)
    #expect(await store.meetings.isEmpty)
    #expect(await session.stop() == .notRecording)
  }

  @Test("cancel while a chunk is mid-transcription saves nothing and leaves no audio")
  func cancelDuringTranscription() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)
    await transcriber.setHook { await session.cancel() }

    try await session.start()
    await session.append(frame(seconds: 1.5), channel: .you)
    let result = await session.stop()

    #expect(result == .cancelled)
    #expect(audioFiles(in: scratch).isEmpty)
    #expect(await store.meetings.isEmpty)
  }

  @Test("a store failure still deletes audio and hands back the transcript")
  func storeFailureKeepsTranscript() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    await store.setFailInsert(true)
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    await session.append(frame(seconds: 1), channel: .you)
    let result = await session.stop()

    guard case .failed(let message, let segments) = result else {
      Issue.record("expected failed, got \(result)")
      return
    }
    #expect(message.contains("disk full"))
    #expect(segments.map(\.text) == ["you#0"])
    #expect(audioFiles(in: scratch).isEmpty)
  }

  @Test("start fails cleanly when the scratch directory cannot be created")
  func startFailureLeavesNothing() async throws {
    let parent = try makeScratch()
    let blocker = parent.appendingPathComponent("not-a-directory")
    FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
    let session = makeSession(
      transcriber: ChunkNamingTranscriber(), store: FakeMeetingStore(),
      scratch: blocker.appendingPathComponent("Scratch"))

    await #expect(throws: (any Error).self) { try await session.start() }
    #expect(await session.stop() == .notRecording)
    #expect(audioFiles(in: parent).isEmpty)
  }

  @Test("chunks abandoned by a crash are swept by the launch-time scratch clear")
  func crashSweep() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("meeting-sweep-\(UUID().uuidString)", isDirectory: true)
    let paths = ApplicationPaths(root: root)
    try FileManager.default.createDirectory(at: paths.scratch, withIntermediateDirectories: true)
    do {
      // Simulates a process that died mid-meeting: started, wrote, never stopped.
      let session = makeSession(
        transcriber: ChunkNamingTranscriber(), store: FakeMeetingStore(), scratch: paths.scratch)
      try await session.start()
      await session.append(frame(seconds: 0.5), channel: .you)
      await session.append(frame(seconds: 0.5), channel: .others)
    }
    #expect(!audioFiles(in: paths.scratch).isEmpty)
    paths.clearScratch()
    #expect(audioFiles(in: paths.scratch).isEmpty)
  }

  @Test("two channels merge into one transcript ordered by time, You before Others on ties")
  func twoChannelMergeOrdering() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    // Others arrives first in wall-clock order; ordering must follow audio time.
    for _ in 0..<2 { await session.append(frame(seconds: 1), channel: .others) }
    for _ in 0..<2 { await session.append(frame(seconds: 1), channel: .you) }
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["you#0", "others#0", "you#1", "others#1"])
    #expect(record.segments.map(\.channel) == [.you, .others, .you, .others])
    #expect(await store.meetings.count == 1)
  }

  @Test("without a model the transcript is saved with no summary and a note saying so")
  func savesWithoutModel() async throws {
    let scratch = try makeScratch()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: ChunkNamingTranscriber(), store: store, scratch: scratch)

    try await session.start()
    await session.append(frame(seconds: 1), channel: .you)
    _ = await session.stop()

    let saved = try #require(await store.meetings.first)
    #expect(saved.summary == nil)
    #expect(saved.summaryNote == MeetingSummarizer.noModelNote)
    #expect(saved.segments.count == 1)
  }
}

@Suite("MeetingTranscript")
struct MeetingTranscriptTests {
  @Test("merge sorts by start time and keeps You first on a tie")
  func mergeOrdering() {
    let merged = MeetingTranscript.merge([
      MeetingSegment(channel: .others, startSeconds: 30, text: "c"),
      MeetingSegment(channel: .others, startSeconds: 0, text: "b"),
      MeetingSegment(channel: .you, startSeconds: 30, text: "d"),
      MeetingSegment(channel: .you, startSeconds: 0, text: "a"),
      MeetingSegment(channel: .you, startSeconds: 60, text: "e"),
    ])
    #expect(merged.map(\.text) == ["a", "b", "d", "c", "e"])
  }

  @Test("renders labelled, timestamped lines")
  func rendering() {
    let text = MeetingTranscript.render([
      MeetingSegment(channel: .you, startSeconds: 0, text: "Hi all"),
      MeetingSegment(channel: .others, startSeconds: 95, text: "Hello"),
    ])
    #expect(text == "[00:00] You: Hi all\n[01:35] Others: Hello")
  }
}
