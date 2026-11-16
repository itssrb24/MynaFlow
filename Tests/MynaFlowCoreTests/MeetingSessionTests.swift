import Foundation
import Testing

@testable import MynaFlowCore

// MARK: - Fakes

/// Transcribes a chunk as "<channel>#<index>" read from its file name, so the
/// result is deterministic whatever order chunks are processed in. Records
/// whether each file still existed when handed over.
private actor ChunkNamingTranscriber: TranscriptionProviding {
  private(set) var seen: [String] = []
  private(set) var hintsSeen: [[String]] = []
  var failingChunkNames: Set<String> = []
  var quietChunkNames: Set<String> = []
  var punctuationChunkNames: Set<String> = []
  var hook: (@Sendable () async -> Void)?
  /// Text to return for a chunk label ("you#0"), instead of the label.
  var scripted: [String: String] = [:]
  /// Word timings to return for a chunk label.
  var scriptedWords: [String: [TimedWord]] = [:]

  func setFailing(_ names: Set<String>) { failingChunkNames = names }
  func setQuiet(_ names: Set<String>) { quietChunkNames = names }
  func setPunctuationOnly(_ names: Set<String>) { punctuationChunkNames = names }
  func setHook(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }
  func setScripted(_ texts: [String: String]) { scripted = texts }
  func setScriptedWords(_ words: [String: [TimedWord]]) { scriptedWords = words }

  func prewarm() async {}

  func transcribe(audio: URL, hints: [String]) async throws -> EngineOutcome {
    let name = audio.deletingPathExtension().lastPathComponent
    seen.append(name)
    hintsSeen.append(hints)
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
      result: TranscriptionResult(
        text: scripted[label] ?? label, durationSeconds: 1, words: scriptedWords[label]),
      engineUsed: .parakeet, fallbackOccurred: false)
  }
}

/// Holds whoever waits until the test opens it — makes "a result arrives
/// after the next meeting started" deterministic instead of a timing race.
private actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}

/// A language model that only counts how often it is asked.
private actor CountingModel: LocalLanguageModel {
  private(set) var calls = 0
  func generateInstruction(_ instruction: String, maxTokens: Int) async throws -> String {
    calls += 1
    return "KEY POINTS\n- Ship it\nACTION ITEMS\n- None"
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
  var earlier: [MeetingRecord] = []
  func setEarlier(_ records: [MeetingRecord]) { earlier = records }
  func previousMeeting(inSeries seriesKey: String, before date: Date) async -> MeetingRecord? {
    earlier.first { $0.context?.seriesKey == seriesKey && $0.startedAt < date }
  }
}

/// Records the prompts it is given; replies with a fixed summary.
private actor PromptRecorder: LocalLanguageModel {
  private(set) var prompts: [String] = []
  func generateInstruction(_ instruction: String, maxTokens: Int) async throws -> String {
    prompts.append(instruction)
    return "OVERVIEW:\nDone.\nKEY POINTS:\n- None\nACTION ITEMS:\n- None"
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

/// Answers each chunk with scripted turns, keyed by the chunk's label
/// ("others#0"); records which chunks it was asked about.
private actor FakeDiarizer: SpeakerDiarizing {
  private(set) var asked: [String] = []
  var turns: [String: [SpeakerTurn]] = [:]
  var failing = false

  func setTurns(_ turns: [String: [SpeakerTurn]]) { self.turns = turns }
  func setFailing(_ failing: Bool) { self.failing = failing }

  func diarize(audio: URL) async throws -> [SpeakerTurn] {
    let parts = audio.deletingPathExtension().lastPathComponent.split(separator: "-")
    let label = "\(parts[parts.count - 2])#\(parts[parts.count - 1])"
    asked.append(label)
    #expect(FileManager.default.fileExists(atPath: audio.path))
    if failing { throw SpeechEngineError("diarizer crashed") }
    return turns[label] ?? []
  }
}

private func makeSession(
  transcriber: ChunkNamingTranscriber,
  store: FakeMeetingStore,
  scratch: URL,
  model: (any LocalLanguageModel)? = nil,
  diarizer: (any SpeakerDiarizing)? = nil
) -> MeetingSession {
  MeetingSession(
    transcriber: transcriber,
    summarizer: MeetingSummarizer(model: model),
    store: store,
    scratchDirectory: scratch,
    diarizer: diarizer,
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

  @Test("a discarded meeting's late transcription never lands in the next meeting")
  func discardedSessionDoesNotLeak() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)
    let gate = Gate()
    await transcriber.setHook { await gate.wait() }

    try await session.start()
    await session.append(frame(seconds: 1), channel: .you)
    // Discard only once chunk you-0 is inside the engine, mid-transcription.
    while await transcriber.seen.isEmpty { await Task.yield() }
    await session.cancel()
    try await session.start()
    await session.append(frame(seconds: 1), channel: .others)
    await gate.open()  // the discarded chunk's text arrives now
    let result = await session.stop()

    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["others#0"])
    #expect(record.summaryNote == MeetingSummarizer.noModelNote)
    #expect(audioFiles(in: scratch).isEmpty)
  }

  @Test("a disk that stops taking audio is reported at once and noted at stop")
  func writeFailureReportedImmediately() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    #expect(await session.append(frame(seconds: 0.5), channel: .you))
    // The open chunk keeps writing, but the next one cannot be created.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scratch.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
    }
    #expect(await session.append(frame(seconds: 0.5), channel: .you) == false)
    #expect(await session.writeFailure != nil)
    #expect(await session.append(frame(seconds: 0.5), channel: .others) == false)

    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["you#0"])
    #expect(record.summaryNote?.contains("Could not write meeting audio") == true)
  }

  @Test("quitting mid-meeting saves the transcript without summarizing, with a note")
  func transcriptOnlyStop() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let store = FakeMeetingStore()
    let model = CountingModel()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch, model: model)

    try await session.start(title: "Weekly sync")
    await session.append(frame(seconds: 1.5), channel: .you)
    let result = await session.stop(summarize: false, cutShortNote: "Saved when Myna Flow quit.")

    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(await model.calls == 0)
    #expect(record.summary == nil)
    #expect(record.segments.map(\.text) == ["you#0"])
    #expect(record.summaryNote == "Saved when Myna Flow quit.")
    #expect(record.eventTitle == "Weekly sync")
    #expect(audioFiles(in: scratch).isEmpty)
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

  @Test("the call heard back through the mic is left out of the saved transcript")
  func echoLeftOut() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    await transcriber.setScripted([
      "you#0": "I think we've got.",
      "others#0": "I think we've got a good going. Let's get started.",
      "you#1": "Yes, my update is on the free trial.",
    ])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)

    try await session.start()
    for _ in 0..<2 { await session.append(frame(seconds: 1), channel: .you) }
    await session.append(frame(seconds: 1), channel: .others)
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.channel) == [.others, .you])
    #expect(record.segments.last?.text == "Yes, my update is on the free trial.")
  }

  @Test("the speech engine hears the invite's names, near-misses are fixed, hallucinations dropped")
  func namesFromInvite() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    await transcriber.setScripted([
      "others#0": "I asked Kokotailo about it.",
      "others#1": "Thank you.",
    ])
    await transcriber.setScriptedWords([
      "others#1": [TimedWord(text: "Thank", start: 0.1, end: 0.3), TimedWord(text: "you.", start: 19, end: 19.5)]
    ])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)
    let context = MeetingContext(
      title: "Sync", attendees: [MeetingAttendee(name: "Daniel Kokotajlo", email: "d@x.com")])
    try await session.start(context: context, vocabulary: ["Gemma"])
    for _ in 0..<2 { await session.append(frame(seconds: 1), channel: .others) }
    guard case .saved(let record) = await session.stop() else {
      Issue.record("expected saved")
      return
    }
    #expect(await transcriber.hintsSeen.first == ["Daniel Kokotajlo", "Gemma"])
    #expect(record.segments.map(\.text) == ["I asked Kokotajlo about it."])
  }

  @Test("with voices on, a known voice is named at stop and profiles are kept; off, nothing is kept")
  func voicesRecognised() async throws {
    var known = [Float](repeating: 0, count: 8)
    known[2] = 1
    let turnsWithVoice = (0..<25).map { index -> SpeakerTurn in
      var v = known
      v[(index % 7) + 1 == 2 ? 3 : (index % 7) + 1] += 0.03 * Float(index % 5)
      return SpeakerTurn(speaker: "spk_1", start: Double(index) * 0.1, end: Double(index) * 0.1 + 0.1, embedding: v)
    }
    let maurice = UUID()
    let candidates = [
      SpeakerMatch.Candidate(
        personID: maurice,
        voiceprints: [VoicePrint(embedding: known, channel: .remote, sampleCount: 4, updatedAt: Date())],
        isInvited: true)
    ]
    for voicesOn in [true, false] {
      let scratch = try makeScratch()
      let diarizer = FakeDiarizer()
      await diarizer.setTurns(["others#0": turnsWithVoice])
      let store = FakeMeetingStore()
      let session = makeSession(
        transcriber: ChunkNamingTranscriber(), store: store, scratch: scratch, diarizer: diarizer)
      try await session.start(
        context: nil,
        voices: voicesOn ? MeetingVoices(candidates: candidates, names: [maurice: "Maurice Lee"]) : nil)
      await session.append(frame(seconds: 1), channel: .others)
      guard case .saved(let record) = await session.stop() else {
        Issue.record("expected saved")
        return
      }
      if voicesOn {
        #expect(record.speakerProfiles.count == 1)
        #expect(record.speakerNames[1] == "Maurice Lee" || record.speakerSuggestions[1] == maurice)
      } else {
        #expect(record.speakerProfiles.isEmpty)
        #expect(record.speakerNames.isEmpty)
      }
    }
  }

  @Test("the summary knows the meeting type and the last meeting in its series")
  func seriesAndType() async throws {
    let scratch = try makeScratch()
    let store = FakeMeetingStore()
    let last = MeetingRecord(
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 60, segments: [],
      summary: MeetingSummary(overview: "Budget still open.", keyPoints: [], actionItems: ["Dan — draft terms"]),
      summaryNote: nil, context: MeetingContext(title: "Weekly standup", seriesKey: "event:S"))
    await store.setEarlier([last])
    let model = PromptRecorder()
    let session = makeSession(transcriber: ChunkNamingTranscriber(), store: store, scratch: scratch, model: model)
    try await session.start(context: MeetingContext(title: "Weekly standup", seriesKey: "event:S"))
    await session.append(frame(seconds: 1), channel: .you)
    guard case .saved(let record) = await session.stop() else {
      Issue.record("expected saved")
      return
    }
    #expect(record.meetingType == .standup)
    let prompt = try #require(await model.prompts.first)
    #expect(prompt.contains("Budget still open."))
    #expect(prompt.contains("Dan — draft terms"))
    #expect(!record.isSummaryStale)
  }

  @Test("a meeting started for an invite is saved with its context")
  func contextSaved() async throws {
    let scratch = try makeScratch()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: ChunkNamingTranscriber(), store: store, scratch: scratch)
    let context = MeetingContext(
      title: "Launch sync", eventID: "E1", seriesKey: "event:E1",
      attendees: [MeetingAttendee(name: "Maurice Lee", email: "maurice@x.com")])
    try await session.start(context: context)
    await session.append(frame(seconds: 1), channel: .you)
    guard case .saved(let record) = await session.stop() else {
      Issue.record("expected saved")
      return
    }
    #expect(record.context == context)
    #expect(record.eventTitle == "Launch sync")
  }

  @Test("an Others chunk is split between the speakers heard in it, numbered by first appearance")
  func othersSplitBySpeaker() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    await transcriber.setScripted(["others#0": "Any updates? Yes, the launch moved."])
    await transcriber.setScriptedWords([
      "others#0": [
        TimedWord(text: "Any", start: 0, end: 0.5), TimedWord(text: "updates?", start: 0.5, end: 1.2),
        TimedWord(text: "Yes,", start: 1.5, end: 1.9), TimedWord(text: "the", start: 1.9, end: 2.1),
        TimedWord(text: "launch", start: 2.1, end: 2.6), TimedWord(text: "moved.", start: 2.6, end: 3.0),
      ]
    ])
    let diarizer = FakeDiarizer()
    await diarizer.setTurns([
      "others#0": [
        SpeakerTurn(speaker: "spk_9", start: 0, end: 1.3), SpeakerTurn(speaker: "spk_4", start: 1.4, end: 3.2),
      ]
    ])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch, diarizer: diarizer)

    try await session.start()
    await session.append(frame(seconds: 1), channel: .others)
    guard case .saved(let record) = await session.stop() else {
      Issue.record("expected saved")
      return
    }
    #expect(record.segments.map(\.text) == ["Any updates?", "Yes, the launch moved."])
    #expect(record.segments.map(\.speaker) == [1, 2])
    #expect(record.segments.map(\.startSeconds) == [0, 1.5])
    #expect(audioFiles(in: scratch).isEmpty)
  }

  @Test("your mic is never diarized, and a speaker keeps one number across chunks")
  func youNotDiarizedAndStableNumbers() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    let diarizer = FakeDiarizer()
    await diarizer.setTurns([
      "others#0": [SpeakerTurn(speaker: "spk_4", start: 0, end: 1)],
      "others#1": [SpeakerTurn(speaker: "spk_4", start: 0, end: 1)],
    ])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch, diarizer: diarizer)

    try await session.start()
    for _ in 0..<2 { await session.append(frame(seconds: 1), channel: .others) }
    await session.append(frame(seconds: 1), channel: .you)
    guard case .saved(let record) = await session.stop() else {
      Issue.record("expected saved")
      return
    }
    #expect(await diarizer.asked.sorted() == ["others#0", "others#1"])
    #expect(record.segments.filter { $0.channel == .others }.map(\.speaker) == [1, 1])
    #expect(record.segments.first { $0.channel == .you }?.speaker == nil)
  }

  @Test("a diarizer failure keeps the text, unlabelled, and still deletes the audio")
  func diarizerFailureKeepsText() async throws {
    let scratch = try makeScratch()
    let diarizer = FakeDiarizer()
    await diarizer.setFailing(true)
    let store = FakeMeetingStore()
    let session = makeSession(
      transcriber: ChunkNamingTranscriber(), store: store, scratch: scratch, diarizer: diarizer)

    try await session.start()
    await session.append(frame(seconds: 1), channel: .others)
    guard case .saved(let record) = await session.stop() else {
      Issue.record("expected saved")
      return
    }
    #expect(record.segments.map(\.text) == ["others#0"])
    #expect(record.segments.first?.speaker == nil)
    #expect(audioFiles(in: scratch).isEmpty)
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

@Suite("MeetingSession — notes, flags and learned words")
struct MeetingSessionNotesTests {
  @Test("notes and flags are stamped with the meeting's audio time and saved")
  func notesAndFlags() async throws {
    let scratch = try makeScratch()
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: ChunkNamingTranscriber(), store: store, scratch: scratch)

    try await session.start(title: "Sync")
    await session.append(frame(seconds: 2.5), channel: .you)
    #expect(await session.addNote("  Ask about budget  "))
    #expect(await !session.addNote("   "))
    #expect(await session.flagMoment())
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.notes.map(\.kind) == [.note, .flag])
    #expect(record.notes.first?.text == "Ask about budget")
    #expect(abs((record.notes.last?.seconds ?? 0) - 2.5) < 0.01)
  }

  @Test("without a meeting, notes and flags are refused")
  func notRecording() async throws {
    let session = makeSession(
      transcriber: ChunkNamingTranscriber(), store: FakeMeetingStore(), scratch: try makeScratch())
    #expect(await !session.addNote("hi"))
    #expect(await !session.flagMoment())
  }

  @Test("approved word replacements apply to meeting text")
  func replacements() async throws {
    let scratch = try makeScratch()
    let transcriber = ChunkNamingTranscriber()
    await transcriber.setScripted(["you#0": "Thanks morris"])
    let store = FakeMeetingStore()
    let session = makeSession(transcriber: transcriber, store: store, scratch: scratch)
    let rules = LearnedRules(
      approved: [LearnedRule(kind: .replacement, pattern: "morris", replacement: "Maurice", evidence: 2)])

    try await session.start(context: nil, replacements: rules)
    await session.append(frame(seconds: 1), channel: .you)
    let result = await session.stop()
    guard case .saved(let record) = result else {
      Issue.record("expected saved, got \(result)")
      return
    }
    #expect(record.segments.map(\.text) == ["Thanks Maurice"])
  }
}
