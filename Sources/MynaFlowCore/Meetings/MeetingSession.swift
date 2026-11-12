import Foundation
import os

/// The slice of the store a meeting needs. FlowStore conforms; tests fake it.
public protocol MeetingStoring: Sendable {
  func insertMeeting(_ record: MeetingRecord) async throws
}

extension FlowStore: MeetingStoring {}

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
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "meeting")

  private let transcriber: any TranscriptionProviding
  private let summarizer: MeetingSummarizer
  private let store: any MeetingStoring
  private let scratchDirectory: URL
  private let chunkSeconds: Double
  private let now: @Sendable () -> Date

  private var sessionID = UUID()
  private var startedAt: Date?
  private var eventTitle: String?
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
    chunkSeconds: Double = 30,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transcriber = transcriber
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
    guard startedAt == nil, !stopping else { return }
    try FileManager.default.createDirectory(
      at: scratchDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    sessionID = UUID()
    eventTitle = title
    cancelled = false
    writeFailure = nil
    untranscribedChunks = 0
    segments = []
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
  public func stop() async -> MeetingStopResult {
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

    let merged = MeetingTranscript.merge(segments)
    let outcome = await summarizer.summarize(merged)
    guard !cancelled else { return finish(.cancelled) }

    let record = MeetingRecord(
      startedAt: startedAt,
      durationSeconds: duration,
      segments: merged,
      summary: Self.summary(outcome),
      summaryNote: Self.note(
        outcome, writeFailure: writeFailure, untranscribed: untranscribedChunks),
      eventTitle: eventTitle)
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
      outcome = try await transcriber.transcribe(audio: chunk.url, hints: [])
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
    let text = outcome.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    Self.log.info(
      "chunk \(chunk.channel.label, privacy: .public) at \(chunk.startSeconds)s → \(text.count) chars")
    // Punctuation alone (a lone ".") is engine noise, not speech.
    guard isCurrent(chunk), text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
    segments.append(
      MeetingSegment(channel: chunk.channel, startSeconds: chunk.startSeconds, text: text))
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
