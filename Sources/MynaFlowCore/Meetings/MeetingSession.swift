import Foundation
import os

/// The slice of the store a meeting needs. FlowStore conforms; tests fake it.
public protocol MeetingStoring: Sendable {
  func insertMeeting(_ record: MeetingRecord) async throws
  /// The latest earlier meeting of a recurring series, for the summary.
  func previousMeeting(inSeries seriesKey: String, before date: Date) async -> MeetingRecord?
}

extension MeetingStoring {
  public func previousMeeting(inSeries seriesKey: String, before date: Date) async -> MeetingRecord? {
    nil
  }
}

extension FlowStore: MeetingStoring {
  public func previousMeeting(inSeries seriesKey: String, before date: Date) async -> MeetingRecord? {
    try? meetings(inSeries: seriesKey, before: date, limit: 1).first
  }
}

public enum MeetingStopResult: Equatable, Sendable {
  /// Saved; `record.summaryNote` explains a missing summary.
  case saved(MeetingRecord)
  /// Could not be saved. The transcript is handed back so the caller can
  /// still offer it to the user — text is never silently lost.
  case failed(message: String, transcript: [MeetingSegment])
  case cancelled
  case notRecording
}

/// Records a meeting as two channels (mic = "You", system output = "Others"),
/// each streamed to 16 kHz WAV chunks that rotate every `chunkSeconds`.
/// Every completed chunk is transcribed in the background and deleted the
/// moment it has been read; cancel deletes everything at once; a crash leaves
/// chunks only in scratch, which the app clears at launch.
///
/// Start and stop are explicit — nothing here detects or starts a meeting.
public actor MeetingSession {
  private struct Chunk: Sendable {
    /// The meeting this audio belongs to. A discarded meeting's chunk can
    /// finish transcribing after the next meeting has started; its text
    /// must never land there.
    let session: UUID
    let url: URL
    let channel: MeetingChannel
    let startSeconds: Double
  }

  /// A channel's open chunk plus the audio time already rotated out.
  private struct ChannelTrack {
    var writer: StreamingWaveWriter
    var url: URL
    var index: Int
    var completedSeconds: Double
    /// Loudest sample so far; a chunk that never rises above the silence
    /// floor is deleted untranscribed rather than reported as a gap.
    var peak: Float = 0
  }

  /// About -50 dBFS: below anything a voice on a call produces.
  static let silenceFloor: Float = 0.003
  /// Chunk lifecycle only — channel, length, level, outcome. Never text.
  private static let log = Logger(subsystem: "app.mynaflow.MynaFlow", category: "meeting")

  private let transcriber: any TranscriptionProviding
  /// Splits "Others" into speakers; nil keeps "Others" as one voice.
  private let diarizer: (any SpeakerDiarizing)?
  private var speakerNumbers = SpeakerNumbering()
  private let summarizer: MeetingSummarizer
  private let store: any MeetingStoring
  private let scratchDirectory: URL
  private let chunkSeconds: Double
  private let now: @Sendable () -> Date

  private var sessionID = UUID()
  private var startedAt: Date?
  /// The invite this meeting is for, when there is one.
  private var context: MeetingContext?
  /// What the engine listens for, and the names near-misses are fixed to.
  private var hints: [String] = []
  private var knownNames: [String] = []
  /// Opted-in voice recognition, and each speaker's samples so far.
  private var voices: MeetingVoices?
  private var voiceSamples: [Int: [SpeakerSample]] = [:]
  private var tracks: [MeetingChannel: ChannelTrack] = [:]
  private var completedChunks: [MeetingChannel: Int] = [:]
  /// Chunk files written but not yet deleted, so cancel can remove them
  /// without waiting on an engine that may be mid-transcription.
  private var liveChunkFiles: Set<URL> = []
  private var segments: [MeetingSegment] = []
  /// Total audio time per channel, recorded as each channel closes at stop.
  private var finishedDurations: [MeetingChannel: Double] = [:]
  private var transcriptionChain: Task<Void, Never>?
  private var cancelled = false
  /// Set for the whole of stop(); a second stop, a cancel once saving has
  /// begun, or a new start cannot interleave with it across its awaits.
  private var stopping = false
  private var saving = false
  /// Why audio stopped being written, once it has. Capture keeps running so
  /// the caller decides whether to stop; what was transcribed is still saved.
  public private(set) var writeFailure: String?
  /// Chunks the engines could not read. Their audio is gone, so the saved
  /// note must say the transcript has gaps.
  private var untranscribedChunks = 0

  public init(
    transcriber: any TranscriptionProviding,
    summarizer: MeetingSummarizer,
    store: any MeetingStoring,
    scratchDirectory: URL,
    diarizer: (any SpeakerDiarizing)? = nil,
    chunkSeconds: Double = 30,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transcriber = transcriber
    self.diarizer = diarizer
    self.summarizer = summarizer
    self.store = store
    self.scratchDirectory = scratchDirectory
    self.chunkSeconds = chunkSeconds
    self.now = now
  }

  public var isRecording: Bool { startedAt != nil && !cancelled }

  /// Completed (rotated-out) chunks for a channel — for tests and the UI.
  public func completedChunkCount(for channel: MeetingChannel) -> Int {
    completedChunks[channel, default: 0]
  }

  /// `title` is the calendar event this meeting was started for, if any.
  public func start(title: String? = nil) throws {
    try start(context: title.map { MeetingContext(title: $0) })
  }

  /// `context` is the invite this meeting is for: title, attendees, agenda.
  /// `vocabulary` is the user's own terms, which the engine also listens for.
  /// `voices`, when the user opted in, recognises known voices at stop.
  public func start(context: MeetingContext?, vocabulary: [String] = [], voices: MeetingVoices? = nil)
    throws
  {
    guard startedAt == nil, !stopping else { return }
    try FileManager.default.createDirectory(
      at: scratchDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    sessionID = UUID()
    self.context = context
    hints = MeetingHints.terms(context: context, vocabulary: vocabulary)
    knownNames = (context?.others.map(\.displayName) ?? []) + vocabulary
    self.voices = voices
    voiceSamples = [:]
    cancelled = false
    writeFailure = nil
    untranscribedChunks = 0
    segments = []
    speakerNumbers = SpeakerNumbering()
    completedChunks = [:]
    do {
      for channel in MeetingChannel.allCases {
        tracks[channel] = try openTrack(channel: channel, index: 0, completedSeconds: 0)
      }
    } catch {
      discardAllAudio()
      throw error
    }
    startedAt = now()
  }

  /// Appends captured audio to a channel, rotating its chunk when full.
  /// Returns false once audio can no longer be written (see `writeFailure`),
  /// so the caller can tell the user right away rather than at stop.
  @discardableResult
  public func append(_ frame: AudioFrame, channel: MeetingChannel) -> Bool {
    guard isRecording else { return true }
    guard writeFailure == nil else { return false }
    guard var track = tracks[channel] else { return true }
    do {
      try track.writer.append(frame)
      track.peak = max(track.peak, frame.samples.lazy.map(abs).max() ?? 0)
      tracks[channel] = track
      if track.writer.durationSeconds >= chunkSeconds {
        try rotate(channel)
      }
    } catch {
      // A disk that cannot take audio ends capture; what was transcribed so
      // far is still saved at stop.
      writeFailure = "Could not write meeting audio: \(error.localizedDescription)"
      return false
    }
    return true
  }

  /// Ends capture, transcribes the remaining audio, summarizes, saves.
  ///
  /// `summarize: false` is for when time is short (the app is quitting): the
  /// transcript is saved without a summary and `cutShortNote` says why.
  public func stop(summarize: Bool = true, cutShortNote: String? = nil) async
    -> MeetingStopResult
  {
    guard let startedAt, !cancelled, !stopping else { return .notRecording }
    stopping = true
    defer {
      stopping = false
      saving = false
    }
    for channel in MeetingChannel.allCases {
      closeTrack(channel)
    }
    let duration = finishedDurations.values.max() ?? 0
    await transcriptionChain?.value
    transcriptionChain = nil
    guard !cancelled else { return finish(.cancelled) }

    // Echoes go before summarizing, so the call's words aren't read twice
    // or credited to the user.
    let merged = MeetingEcho.removeEchoes(MeetingTranscript.merge(segments), window: chunkSeconds)
    // Counts only — never the words — so the exportable log stays content-free.
    DiagnosticsLog.shared.write(
      "info", "meeting",
      "stop: segments=\(segments.count) echoesDropped=\(segments.count - merged.count) "
        + "you=\(merged.filter { $0.channel == .you }.count) "
        + "others=\(merged.filter { $0.channel == .others }.count)")
    let attendees = context?.attendees ?? []
    let type = MeetingType.infer(
      title: context?.title, agenda: context?.agenda, attendeeCount: attendees.count,
      external: MeetingType.hasExternal(attendees))
    // A recurring meeting's summary can say what moved on since last time.
    var previous: PreviousMeeting?
    if summarize, let seriesKey = context?.seriesKey,
      let last = await store.previousMeeting(inSeries: seriesKey, before: startedAt)
    {
      previous = PreviousMeeting(
        overview: last.summary?.overview, openActions: last.summary?.actionItems ?? [])
    }
    // Known voices are named before summarizing, so the summary uses them.
    var profiles: [SpeakerProfile] = []
    var recognised = VoiceRecognition.Result()
    if let voices {
      profiles = SpeakerProfiler.profiles(from: voiceSamples)
      recognised = VoiceRecognition.recognise(profiles, candidates: voices.candidates)
    }
    let names = recognised.named.compactMapValues { voices?.names[$0] }
    let draft = MeetingRecord(
      startedAt: startedAt, durationSeconds: duration, segments: merged, summary: nil,
      summaryNote: nil, eventTitle: context?.title, speakerNames: names, context: context,
      meetingType: type, speakerPeople: recognised.named.filter { names[$0.key] != nil },
      speakerProfiles: profiles, speakerSuggestions: recognised.suggested)
    let outcome =
      summarize
      ? await summarizer.summarize(merged, context: draft.summaryContext(previous: previous))
      : .unavailable(cutShortNote ?? "Not summarized.")
    guard !cancelled else { return finish(.cancelled) }

    let record = draft.replacingSummary(
      Self.summary(outcome),
      note: Self.note(outcome, writeFailure: writeFailure, untranscribed: untranscribedChunks),
      type: type)
    // Past this point the meeting is being written; a cancel can no longer
    // un-save it, so it is ignored rather than half-honoured.
    saving = true
    do {
      try await store.insertMeeting(record)
    } catch {
      return finish(.failed(message: "Could not save the meeting: \(error)", transcript: merged))
    }
    return finish(.saved(record))
  }

  /// Abandons the meeting: deletes every chunk now, saves nothing. Does not
  /// wait for an in-flight transcription; its result is discarded.
  public func cancel() {
    guard startedAt != nil, !cancelled, !saving else { return }
    cancelled = true
    startedAt = nil
    transcriptionChain?.cancel()
    // Detach: the next meeting must not wait on, or inherit, this chain.
    transcriptionChain = nil
    discardAllAudio()
  }

  // MARK: - Chunks

  private func openTrack(channel: MeetingChannel, index: Int, completedSeconds: Double) throws
    -> ChannelTrack
  {
    let url = scratchDirectory.appendingPathComponent(
      "meeting-\(sessionID.uuidString)-\(channel.rawValue)-\(index).wav", isDirectory: false)
    liveChunkFiles.insert(url)
    do {
      let writer = try StreamingWaveWriter(url: url, outputSampleRate: 16_000)
      return ChannelTrack(writer: writer, url: url, index: index, completedSeconds: completedSeconds)
    } catch {
      delete(url)
      throw error
    }
  }

  private func rotate(_ channel: MeetingChannel) throws {
    guard let track = tracks[channel] else { return }
    let next = track.completedSeconds + track.writer.durationSeconds
    closeTrack(channel)
    tracks[channel] = try openTrack(channel: channel, index: track.index + 1, completedSeconds: next)
  }

  /// Finishes a channel's open chunk and queues it — or deletes it if empty.
  private func closeTrack(_ channel: MeetingChannel) {
    guard let track = tracks.removeValue(forKey: channel) else { return }
    let duration = track.writer.durationSeconds
    let finished = (try? track.writer.finish()) != nil
    finishedDurations[channel] = track.completedSeconds + duration
    Self.log.info(
      "chunk \(channel.label, privacy: .public)-\(track.index): \(duration, format: .fixed(precision: 1))s peak \(track.peak, format: .fixed(precision: 4)) written=\(finished)"
    )
    guard finished, track.writer.samplesWritten > 0, track.peak >= Self.silenceFloor else {
      delete(track.url)
      return
    }
    completedChunks[channel, default: 0] += 1
    enqueue(
      Chunk(
        session: sessionID, url: track.url, channel: channel,
        startSeconds: track.completedSeconds))
  }

  /// Chunks transcribe one at a time, in the order they were cut, so the
  /// engine never runs two jobs concurrently on a call-length workload.
  private func enqueue(_ chunk: Chunk) {
    let previous = transcriptionChain
    transcriptionChain = Task {
      await previous?.value
      await self.transcribe(chunk)
    }
  }

  private func transcribe(_ chunk: Chunk) async {
    defer { delete(chunk.url) }
    guard isCurrent(chunk), !Task.isCancelled else { return }
    let outcome: EngineOutcome
    do {
      outcome = try await transcriber.transcribe(audio: chunk.url, hints: hints)
    } catch let error as SpeechEngineError where error == .nothingRecognized {
      // Room noise above the silence floor but no words: nothing was lost.
      Self.log.info(
        "chunk \(chunk.channel.label, privacy: .public) at \(chunk.startSeconds)s: no speech")
      return
    } catch {
      // A real engine failure: the note records that this stretch has no text.
      Self.log.error(
        "chunk \(chunk.channel.label, privacy: .public) at \(chunk.startSeconds)s not transcribed: \(String(describing: type(of: error)), privacy: .public)"
      )
      if isCurrent(chunk) { untranscribedChunks += 1 }
      return
    }
    // Words spread thinly over near-silence are the engine inventing them.
    if SpeechSanity.isHallucination(words: outcome.result.words) {
      Self.log.info("chunk \(chunk.channel.label, privacy: .public) at \(chunk.startSeconds)s: dropped as hallucination")
      return
    }
    let text = NameCorrector.correct(
      outcome.result.text.trimmingCharacters(in: .whitespacesAndNewlines), knownNames: knownNames)
    Self.log.info(
      "chunk \(chunk.channel.label, privacy: .public) at \(chunk.startSeconds)s → \(text.count) chars")
    // Punctuation alone (a lone ".") is engine noise, not speech.
    guard isCurrent(chunk), text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
    guard chunk.channel == .others, let diarizer else {
      segments.append(
        MeetingSegment(channel: chunk.channel, startSeconds: chunk.startSeconds, text: text))
      return
    }
    // The chunk file still exists here; the deferred delete runs after.
    let turns: [SpeakerTurn]
    do {
      turns = try await diarizer.diarize(audio: chunk.url)
    } catch {
      // Speakers are a nicety: the text is kept, as plain "Others".
      Self.log.error(
        "chunk at \(chunk.startSeconds)s not diarized: \(String(describing: type(of: error)), privacy: .public)")
      turns = []
    }
    guard isCurrent(chunk) else { return }
    if voices != nil {
      // Numbers only — the samples become a profile at stop; audio is still deleted.
      for turn in turns {
        guard let embedding = turn.embedding, turn.end > turn.start else { continue }
        voiceSamples[speakerNumbers.number(for: turn.speaker), default: []]
          .append(SpeakerSample(embedding: embedding, seconds: turn.end - turn.start))
      }
    }
    let pieces = SpeakerAlignment.pieces(
      text: text, words: outcome.result.words, duration: chunkSeconds, turns: turns)
    Self.log.info("chunk at \(chunk.startSeconds)s: \(turns.count) turns → \(pieces.count) pieces")
    for piece in pieces {
      // Split pieces are rebuilt from timed words, which skip the fix above.
      let pieceText = NameCorrector.correct(
        piece.text.trimmingCharacters(in: .whitespacesAndNewlines), knownNames: knownNames)
      guard pieceText.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
      segments.append(
        MeetingSegment(
          channel: .others, startSeconds: chunk.startSeconds + piece.start, text: pieceText,
          speaker: piece.speaker.map { speakerNumbers.number(for: $0) }))
    }
  }

  /// Whether a chunk's result still belongs to a live meeting.
  private func isCurrent(_ chunk: Chunk) -> Bool {
    !cancelled && chunk.session == sessionID
  }

  private func delete(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    liveChunkFiles.remove(url)
  }

  private func discardAllAudio() {
    for track in tracks.values {
      try? track.writer.finish()
    }
    tracks = [:]
    for url in liveChunkFiles {
      try? FileManager.default.removeItem(at: url)
    }
    liveChunkFiles = []
  }

  private func finish(_ result: MeetingStopResult) -> MeetingStopResult {
    discardAllAudio()
    startedAt = nil
    finishedDurations = [:]
    segments = []
    return result
  }

  // MARK: - Summary mapping

  private static func summary(_ outcome: MeetingSummaryOutcome) -> MeetingSummary? {
    if case .summarized(let summary) = outcome { return summary }
    return nil
  }

  private static func note(
    _ outcome: MeetingSummaryOutcome, writeFailure: String?, untranscribed: Int
  ) -> String? {
    let summaryNote: String? =
      switch outcome {
      case .summarized: nil
      case .unavailable(let reason): reason
      case .failed(let reason): "No summary: \(reason) The transcript was saved."
      }
    let gaps: String? =
      untranscribed == 0
      ? nil
      : "\(untranscribed) part\(untranscribed == 1 ? "" : "s") of the audio could not be "
        + "transcribed (the speech engine failed), so the transcript may have gaps."
    let notes = [writeFailure, gaps, summaryNote].compactMap { $0 }
    return notes.isEmpty ? nil : notes.joined(separator: " ")
  }
}
