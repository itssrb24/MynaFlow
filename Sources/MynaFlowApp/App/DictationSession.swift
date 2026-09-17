import AppKit
import MynaFlowCore
import os

/// The one owner of the dictation lifecycle on the app side. Feeds hotkey and
/// system events into `DictationSessionPolicy` and executes the effects it
/// returns: microphone capture, timers, the indicator, and the controller.
/// Nothing else in the app starts or stops capture.
@MainActor
final class DictationSession {
  nonisolated private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "session")

  private var policy = DictationSessionPolicy()
  private let capture: MicrophoneCapture
  private let indicator: IndicatorModel
  private let indicatorPanel: IndicatorPanelController?
  private let permissions: PermissionManager
  private let scratchDirectory: URL
  private(set) var controller: DictationController?
  private var pendingController: DictationController?

  private var frameCollector: Task<Void, Never>?
  private var elapsedTimer: Task<Void, Never>?
  private var autoStop: Task<Void, Never>?
  private var startTask: Task<Void, Never>?

  var toggleMaximumDuration: Duration = .seconds(600)
  /// Subtle start/stop ticks; off by default.
  var soundFeedback = false
  /// Whether the controller is busy with a previous dictation (processing or
  /// inserting) — decides what a refused start should do to the indicator.
  var isControllerBusy: () -> Bool = { false }
  /// Called after every finished dictation (history refresh).
  var onFinished: () async -> Void = {}
  var onError: (String) -> Void = { _ in }

  init(
    capture: MicrophoneCapture, indicator: IndicatorModel,
    indicatorPanel: IndicatorPanelController?, permissions: PermissionManager,
    scratchDirectory: URL
  ) {
    self.capture = capture
    self.scratchDirectory = scratchDirectory
    self.indicator = indicator
    self.indicatorPanel = indicatorPanel
    self.permissions = permissions
    capture.onConfigurationChange = { [weak self] in self?.handle(.deviceLost) }
  }

  var isIdle: Bool { policy.isIdle }
  var phase: DictationSessionPolicy.Phase { policy.phase }

  /// Controllers are only swapped between dictations; a swap requested
  /// mid-flight waits for idle so the in-flight dictation keeps its owner.
  func replaceController(_ controller: DictationController) {
    if policy.isIdle {
      self.controller = controller
      pendingController = nil
    } else {
      pendingController = controller
    }
  }

  func handle(_ input: DictationSessionPolicy.Input) {
    let effects = policy.handle(input)
    for effect in effects { perform(effect) }
    if policy.isIdle, let pending = pendingController {
      controller = pending
      pendingController = nil
    }
  }

  // MARK: - Effects

  private func perform(_ effect: DictationSessionPolicy.Effect) {
    switch effect {
    case .beginStart(let mode):
      beginStart(mode)
    case .startCapture:
      startCapture()
      if soundFeedback { NSSound(named: "Tink")?.play() }
    case .stopCapture:
      stopElapsedTimer()
      capture.stop()
      if soundFeedback { NSSound(named: "Pop")?.play() }
    case .cancelController:
      frameCollector?.cancel()
      frameCollector = nil
      stopElapsedTimer()
      capture.stop()
      if let controller { Task { await controller.cancelDictation() } }
    case .armAutoStop:
      autoStop?.cancel()
      autoStop = Task { [weak self] in
        try? await Task.sleep(for: self?.toggleMaximumDuration ?? .seconds(600))
        guard !Task.isCancelled else { return }
        self?.handle(.autoStop)
      }
    case .disarmAutoStop:
      autoStop?.cancel()
      autoStop = nil
    case .hideIndicator:
      indicator.display = .hidden
      indicatorPanel?.hide()
    case .startFailedIndicator:
      // A refused start while the previous dictation is still transcribing
      // keeps that indicator; otherwise nothing is happening — hide.
      if !isControllerBusy() {
        indicator.display = .hidden
        indicatorPanel?.hide()
      }
    case .notifyDeviceLost:
      Self.log.warning("input device changed mid-recording; finishing with captured audio")
      onError("Microphone changed — transcribing what was captured")
    }
  }

  private func beginStart(_ mode: DictationMode) {
    guard permissions.microphoneAuthorization == .authorized else {
      Task { _ = await permissions.requestMicrophonePermission() }
      handle(.startFailed)
      return
    }
    guard let controller else {
      handle(.startFailed)
      return
    }
    // The indicator appears on the hotkey edge — the <100 ms budget — before
    // any async work.
    indicator.display = .recording(mode: mode == .hold ? .hold : .toggle)
    indicator.audioLevel = 0
    indicator.elapsedSeconds = 0
    indicatorPanel?.show()

    startTask?.cancel()
    startTask = Task { [weak self] in
      let started = await controller.startDictation(mode: mode)
      guard !Task.isCancelled else { return }
      self?.handle(started ? .startSucceeded : .startFailed)
    }
  }

  private func startCapture() {
    guard let controller else {
      handle(.cancel)
      return
    }
    do {
      // Frames stream straight into a 16 kHz scratch WAV, so a 10-minute
      // toggle session never holds its audio in memory.
      try FileManager.default.createDirectory(
        at: scratchDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let wavURL = scratchDirectory.appendingPathComponent(
        "dictation-\(UUID().uuidString).wav", isDirectory: false)
      let writer = try StreamingWaveWriter(url: wavURL, outputSampleRate: 16_000)
      let frames = try capture.start { [weak self] level in
        self?.indicator.audioLevel = level
        Task { await controller.updateAudioLevel(level) }
      }
      startElapsedTimer()
      frameCollector = Task { [weak self] in
        var writeFailed = false
        for await frame in frames {
          do { try writer.append(frame) } catch { writeFailed = true }
        }
        try? writer.finish()
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: wavURL)
          return
        }
        // Capture is over: the session is free again while transcription runs.
        self?.frameCollector = nil
        self?.handle(.captureFinished)
        await controller.finishRecording(
          audio: wavURL, hasAudio: writer.samplesWritten > 0 && !writeFailed)
        await self?.onFinished()
      }
    } catch {
      Self.log.error("mic capture failed: \(error)")
      handle(.cancel)
      onError("Microphone unavailable")
    }
  }

  private func startElapsedTimer() {
    elapsedTimer?.cancel()
    elapsedTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self?.indicator.elapsedSeconds += 1
      }
    }
  }

  private func stopElapsedTimer() {
    elapsedTimer?.cancel()
    elapsedTimer = nil
  }
}
