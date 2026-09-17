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
  private(set) var controller: DictationController?
  private var pendingController: DictationController?

  private var frameCollector: Task<Void, Never>?
  private var elapsedTimer: Task<Void, Never>?
  private var autoStop: Task<Void, Never>?
  private var startTask: Task<Void, Never>?

  var toggleMaximumDuration: Duration = .seconds(600)
  /// Whether the controller is busy with a previous dictation (processing or
  /// inserting) — decides what a refused start should do to the indicator.
  var isControllerBusy: () -> Bool = { false }
  /// Called after every finished dictation (history refresh).
  var onFinished: () async -> Void = {}
  var onError: (String) -> Void = { _ in }

  init(
    capture: MicrophoneCapture, indicator: IndicatorModel,
    indicatorPanel: IndicatorPanelController?, permissions: PermissionManager
  ) {
    self.capture = capture
    self.indicator = indicator
    self.indicatorPanel = indicatorPanel
    self.permissions = permissions
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
    case .stopCapture:
      stopElapsedTimer()
      capture.stop()
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
    let buffer = DictationAudioBuffer()
    do {
      let frames = try capture.start { [weak self] level in
        self?.indicator.audioLevel = level
        Task { await controller.updateAudioLevel(level) }
      }
      startElapsedTimer()
      frameCollector = Task { [weak self] in
        for await frame in frames {
          await buffer.append(frame)
        }
        guard !Task.isCancelled else { return }
        let collected = await buffer.frames()
        // Capture is over: the session is free again while transcription runs.
        self?.frameCollector = nil
        self?.handle(.captureFinished)
        await controller.finishRecording(frames: collected)
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
