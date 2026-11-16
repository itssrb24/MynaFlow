import AVFoundation
import FluidAudio
import Foundation
import MynaFlowCore
import os

/// Tells the voices in "Others" apart for one meeting. FluidAudio's
/// `DiarizerManager` (pyannote segmentation + WeSpeaker embeddings) keeps its
/// speaker database for its lifetime, so one instance per meeting keeps
/// "Speaker 2" the same person from chunk to chunk. It reads each chunk file;
/// the session deletes it afterwards, so audio is never kept.
actor MeetingDiarizer: SpeakerDiarizing {
  private static let log = Logger(subsystem: "app.mynaflow.MynaFlow", category: "speakers")
  private let manager: DiarizerManager

  init(models: DiarizerModels) {
    manager = DiarizerManager()
    manager.initialize(models: models)
  }

  func diarize(audio: URL) async throws -> [SpeakerTurn] {
    let samples = try Self.read16kMono(audio)
    // Under a second there is no voice to profile; leave the chunk unlabelled.
    guard samples.count > 16_000 else { return [] }
    let started = Date()
    let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
    Self.log.info(
      "diarized \(samples.count / 16_000)s in \(Int(Date().timeIntervalSince(started) * 1000))ms → \(result.segments.count) turns"
    )
    return result.segments.map {
      SpeakerTurn(
        speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
        embedding: $0.embedding.isEmpty ? nil : $0.embedding)
    }
  }

  /// Meeting chunks are written as 16 kHz mono WAV; read them as floats.
  private static func read16kMono(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard file.length > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
    else { return [] }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    return format.sampleRate == 16_000
      ? samples : BandlimitedResampler.resample(samples, from: format.sampleRate, to: 16_000)
  }
}

/// Speaker separation for meeting notes: the ~14 MB diarization models, an
/// explicit install, and the user's on/off choice. Nothing downloads unless
/// the user clicks Install; once installed the models load from this Mac.
@MainActor
@Observable
final class SpeakerSeparation {
  enum State: Equatable {
    case notInstalled
    case installing(Double)
    case installed
    case failed(String)
  }

  private static let log = Logger(subsystem: "app.mynaflow.MynaFlow", category: "speakers")
  static let settingKey = "speaker_separation"

  private(set) var state: State = .notInstalled
  private(set) var isEnabled = false
  /// Opt-in: remember voices of people the user names, and recognise them
  /// in later meetings. Off by default.
  private(set) var recognisesVoices = false
  static let voicesKey = "recognise_voices"

  @ObservationIgnored private var directory: URL?
  @ObservationIgnored private var store: FlowStore?
  @ObservationIgnored private var models: DiarizerModels?

  func configure(modelsDirectory: URL, store: FlowStore) async {
    directory = modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    self.store = store
    state = filesPresent ? .installed : .notInstalled
    let saved = try? await store.setting(forKey: Self.settingKey)
    isEnabled = state == .installed && saved != "0"
    recognisesVoices = (try? await store.setting(forKey: Self.voicesKey)) == "1"
  }

  /// Explicit, user-approved download from huggingface.co (pinned), then on.
  func install() {
    guard let directory, state != .installed else { return }
    state = .installing(0)
    Task {
      do {
        ParakeetEngine.pinModelRegistry()
        models = try await DiarizerModels.download(to: directory) { [weak self] progress in
          Task { @MainActor in self?.state = .installing(progress.fractionCompleted) }
        }
        state = .installed
        setEnabled(true)
      } catch {
        Self.log.error("speaker models install failed: \(error.localizedDescription)")
        state = .failed("Couldn't download the speaker models. Check your connection and try again.")
      }
    }
  }

  func setRecognisesVoices(_ on: Bool) {
    recognisesVoices = on
    Task { try? await store?.setSetting(on ? "1" : "0", forKey: Self.voicesKey) }
  }

  /// Deletes every voice profile and stored speaker sample, and turns
  /// recognition off.
  func forgetAllVoices() async {
    try? await store?.forgetAllVoices()
    setRecognisesVoices(false)
  }

  /// What a meeting needs to recognise known voices, when opted in.
  func meetingVoices(invited emails: Set<String>) async -> MeetingVoices? {
    guard isEnabled, recognisesVoices, let store else { return nil }
    let candidates = (try? await store.voiceCandidates(invited: emails)) ?? []
    let people = (try? await store.people()) ?? []
    return MeetingVoices(
      candidates: candidates,
      names: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) }))
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled && state == .installed
    let value = isEnabled ? "1" : "0"
    Task { try? await store?.setSetting(value, forKey: Self.settingKey) }
  }

  /// A fresh diarizer for one meeting, or nil when separation is off or the
  /// models can't load — the meeting then records "Others" as one voice.
  func makeDiarizer() async -> MeetingDiarizer? {
    guard isEnabled, let directory else { return nil }
    if models == nil {
      do {
        models = try DiarizerModels.load(
          localSegmentationModel: directory.appendingPathComponent(ModelNames.Diarizer.segmentationFile),
          localEmbeddingModel: directory.appendingPathComponent(ModelNames.Diarizer.embeddingFile))
      } catch {
        Self.log.error("speaker models failed to load: \(error.localizedDescription)")
        return nil
      }
    }
    return models.map { MeetingDiarizer(models: $0) }
  }

  private var filesPresent: Bool {
    guard let directory else { return false }
    return [ModelNames.Diarizer.segmentationFile, ModelNames.Diarizer.embeddingFile].allSatisfy {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }
}
