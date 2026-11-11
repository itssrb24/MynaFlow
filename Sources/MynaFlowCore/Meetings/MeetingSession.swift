import Foundation

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
  }

  private let transcriber: any TranscriptionProviding
  private let summarizer: MeetingSummarizer
  private let store: any MeetingStoring
  private let scratchDirectory: URL
  private let chunkSeconds: Double
  private let now: @Sendable () -> Date

  private var sessionID = UUID()
  private var startedAt: Date?
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
  private var writeFailure: String?

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

  public func start() throws {
    guard startedAt == nil else { return }
    try FileManager.default.createDirectory(
      at: scratchDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    sessionID = UUID()
    cancelled = false
    writeFailure = nil
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
  public func append(_ frame: AudioFrame, channel: MeetingChannel) {
    guard isRecording, writeFailure == nil, var track = tracks[channel] else { return }
    do {
      try track.writer.append(frame)
      tracks[channel] = track
      if track.writer.durationSeconds >= chunkSeconds {
        try rotate(channel)
      }
    } catch {
      // A disk that cannot take audio ends capture; what was transcribed so
      // far is still saved at stop.
      writeFailure = "Could not write meeting audio: \(error.localizedDescription)"
    }
  }

  /// Ends capture, transcribes the remaining audio, summarizes, saves.
  public func stop() async -> MeetingStopResult {
    guard let startedAt, !cancelled else { return .notRecording }
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
      summaryNote: Self.note(outcome, writeFailure: writeFailure))
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
    guard startedAt != nil, !cancelled else { return }
    cancelled = true
    startedAt = nil
    transcriptionChain?.cancel()
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
    guard finished, track.writer.samplesWritten > 0 else {
      delete(track.url)
      return
    }
    completedChunks[channel, default: 0] += 1
    enqueue(Chunk(url: track.url, channel: channel, startSeconds: track.completedSeconds))
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
    guard !cancelled, !Task.isCancelled else { return }
    let outcome = try? await transcriber.transcribe(audio: chunk.url, hints: [])
    guard !cancelled, let text = outcome?.result.text.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return }
    segments.append(
      MeetingSegment(channel: chunk.channel, startSeconds: chunk.startSeconds, text: text))
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

  private static func note(_ outcome: MeetingSummaryOutcome, writeFailure: String?) -> String? {
    let summaryNote: String? =
      switch outcome {
      case .summarized: nil
      case .unavailable(let reason): reason
      case .failed(let reason): "No summary: \(reason) The transcript was saved."
      }
    let notes = [writeFailure, summaryNote].compactMap { $0 }
    return notes.isEmpty ? nil : notes.joined(separator: " ")
  }
}
