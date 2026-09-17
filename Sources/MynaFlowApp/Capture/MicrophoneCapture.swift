import AVFoundation
import MynaFlowCore
import os

@MainActor
final class MicrophoneCapture {
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "audio")

  private let engine = AVAudioEngine()
  private var continuation: AsyncStream<AudioFrame>.Continuation?
  private let latestLevel = OSAllocatedUnfairLock<Float>(initialState: 0)
  private var levelTask: Task<Void, Never>?
  /// Whether the voice-processing unit is up, so teardown only runs against a
  /// unit that exists — enabling it is best-effort and some devices refuse.
  private var voiceProcessingActive = false

  private static let levelUpdateInterval: Duration = .milliseconds(16)  // ~60 Hz

  /// Capture device UID; nil follows the system default input.
  var preferredDeviceUID: String?
  /// Fires when the engine's input graph changes underneath a running
  /// capture — device unplugged, default input switched, or a wake from
  /// sleep. The stream is finished; the owner decides what to do with the
  /// frames collected so far.
  var onConfigurationChange: @MainActor () -> Void = {}
  private var configurationObserver: (any NSObjectProtocol)?

  func start(levelChanged: @escaping @MainActor @Sendable (Float) -> Void) throws
    -> AsyncStream<AudioFrame>
  {
    stop()
    let input = engine.inputNode
    if let uid = preferredDeviceUID, var deviceID = AudioDevices.deviceID(forUID: uid),
      let unit = input.audioUnit
    {
      let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
      if status != noErr {
        Self.log.warning("could not select input device \(uid): \(status)")
      }
    }
    // Voice processing for dictation: one near-field talker is exactly the
    // case Apple's AEC/noise suppression is tuned for, and dictation has no
    // second in-room speaker to lose. Set before the format is read, since
    // enabling it changes the node's format.
    do {
      try input.setVoiceProcessingEnabled(true)
      voiceProcessingActive = true
    } catch {
      Self.log.warning("voice processing unavailable: \(error.localizedDescription)")
    }
    let format = input.outputFormat(forBus: 0)
    let stream = AsyncStream<AudioFrame> { continuation in
      self.continuation = continuation
    }
    let continuation = self.continuation
    let tap = Self.makeTap(
      continuation: continuation,
      sampleRate: format.sampleRate,
      latestLevel: latestLevel
    )
    input.installTap(onBus: 0, bufferSize: 2_048, format: format, block: tap)
    engine.prepare()
    try engine.start()
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.continuation != nil else { return }
        Self.log.warning("audio engine configuration changed mid-capture")
        self.onConfigurationChange()
      }
    }

    // Deliver the most recent audio level at a bounded rate from a single task,
    // instead of spawning one Task per audio buffer on the real-time tap thread.
    let level = latestLevel
    levelTask = Task { @MainActor in
      while !Task.isCancelled {
        levelChanged(level.withLock { $0 })
        try? await Task.sleep(for: Self.levelUpdateInterval)
      }
    }
    return stream
  }

  nonisolated private static func makeTap(
    continuation: AsyncStream<AudioFrame>.Continuation?,
    sampleRate: Double,
    latestLevel: OSAllocatedUnfairLock<Float>
  ) -> AVAudioNodeTapBlock {
    { buffer, _ in
      guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
      let count = Int(buffer.frameLength)
      let samples = Array(UnsafeBufferPointer(start: channels[0], count: count))
      let sum = samples.reduce(Float.zero) { $0 + $1 * $1 }
      let rms = min(1, sqrt(sum / Float(max(count, 1))) * 8)
      continuation?.yield(AudioFrame(samples: samples, sampleRate: sampleRate))
      latestLevel.withLock { $0 = rms }
    }
  }

  func stop() {
    levelTask?.cancel()
    levelTask = nil
    latestLevel.withLock { $0 = 0 }
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    // Remove the tap unconditionally: after a configuration change or a
    // failed start the engine reports not-running while the tap (and the
    // continuation) are still installed.
    engine.inputNode.removeTap(onBus: 0)
    if engine.isRunning {
      engine.stop()
    }
    // `engine.stop()` does NOT release the voice-processing unit. Left up, it
    // holds the microphone session and keeps its system-wide ducking of other
    // apps' output alive until the process exits — dictation arming the unit
    // on every hotkey press and never releasing it would leak the mic session.
    // Legal only once the engine is stopped, since it changes the node's
    // format — hence the ordering.
    if voiceProcessingActive {
      do {
        try engine.inputNode.setVoiceProcessingEnabled(false)
      } catch {
        Self.log.warning("voice processing teardown failed: \(error.localizedDescription)")
      }
      voiceProcessingActive = false
    }
    continuation?.finish()
    continuation = nil
  }
}

/// Retains a dictation's mic frames for the length of that dictation so the
/// transcriber consumes a complete recording after key-up. Discarded — never
/// persisted — as soon as transcription finishes.
actor DictationAudioBuffer {
  private var collected: [AudioFrame] = []

  func append(_ frame: AudioFrame) { collected.append(frame) }

  func frames() -> [AudioFrame] { collected }
}
