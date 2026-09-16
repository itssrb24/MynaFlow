import AVFoundation
import FluidAudio
import Foundation
import MynaFlowCore
import os

/// Parakeet v3 via FluidAudio's offline Unified manager (FastConformer-RNNT,
/// int8 encoder on the Neural Engine). Better accuracy than Apple Speech on
/// technical vocabulary; falls back to Apple through the EngineCoordinator.
///
/// Network policy: `prepare()`/`transcribe` only ever load from disk. The one
/// network-capable path is `install(progress:)`, which the user invokes
/// explicitly; FluidAudio's ModelHub downloads with completeness checks and
/// purge-and-retry recovery.
actor ParakeetEngine: SpeechEngine, TranscriptionProviding {
  nonisolated let id: EngineID = .parakeet
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "parakeet")

  /// Rough size of the int8 offline bundle set, for consent copy.
  static let approximateDownloadMegabytes = 600

  private let manager = UnifiedAsrManager()
  /// Base directory the models live under (Myna Flow's own Application
  /// Support, not FluidAudio's default).
  private let modelsBaseDirectory: URL
  private var loaded = false

  init(modelsBaseDirectory: URL) {
    self.modelsBaseDirectory = modelsBaseDirectory
  }

  private var cacheDirectory: URL {
    modelsBaseDirectory.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
  }

  nonisolated private static var requiredFiles: [String] {
    [
      ModelNames.ParakeetUnified.offlineEncoderInt8File,
      ModelNames.ParakeetUnified.decoderFile,
      ModelNames.ParakeetUnified.jointDecisionFile,
      ModelNames.ParakeetUnified.vocab,
    ]
  }

  var isInstalled: Bool {
    let directory = cacheDirectory
    return Self.requiredFiles.allSatisfy {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }

  var isAvailable: Bool {
    get async { isInstalled }
  }

  /// Load models from disk if installed. Never downloads.
  func prepare() async {
    guard !loaded, isInstalled else { return }
    do {
      try await manager.loadModels(from: cacheDirectory)
      loaded = true
    } catch {
      Self.log.error("Parakeet load failed: \(error)")
    }
  }

  /// Explicit, user-approved download + load.
  func install(progress: @escaping @Sendable (Double) -> Void) async throws {
    try await manager.loadModels(to: modelsBaseDirectory) { downloadProgress in
      progress(downloadProgress.fractionCompleted)
    }
    loaded = true
  }

  func remove() throws {
    loaded = false
    try FileManager.default.removeItem(at: cacheDirectory)
  }

  func transcribe(audio: URL, hints: [String]) async throws -> TranscriptionResult {
    if !loaded { await prepare() }
    guard loaded else { throw SpeechEngineError("Parakeet models are not installed") }
    let (samples, duration) = try Self.read16kMono(from: audio)
    let text = try await manager.transcribe(samples)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw SpeechEngineError("nothing recognized") }
    return TranscriptionResult(text: text, durationSeconds: duration)
  }

  /// Decode any WAV/AIFF into 16 kHz mono Float samples. Dictation WAVs are
  /// already 16 kHz mono, so the resample is usually a no-op.
  nonisolated private static func read16kMono(from url: URL) throws -> ([Float], Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else { throw SpeechEngineError("empty or unreadable audio file") }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else {
      throw SpeechEngineError("unsupported audio format")
    }
    let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    let duration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
    let resampled = BandlimitedResampler.resample(
      samples, from: format.sampleRate, to: 16_000)
    return (resampled, duration)
  }
}
