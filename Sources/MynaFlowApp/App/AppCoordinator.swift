import AppKit
import MynaFlowCore
import SwiftUI
import os

/// Wires the whole Phase 1 loop together: hotkeys → capture → controller →
/// indicator. Owned by the app for its lifetime.
@MainActor
@Observable
final class AppCoordinator {
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "app")

  let indicator = IndicatorModel()
  private(set) var recentDictations: [DictationRecord] = []
  private(set) var menuBarState: MenuBarState = .idle

  enum MenuBarState {
    case idle
    case recording
    case processing
  }

  private var controller: DictationController?
  private var store: FlowStore?
  private var appleEngine: AppleSpeechEngine?
  private var parakeetEngine: ParakeetEngine?
  private var paths: ApplicationPaths?
  private(set) var parakeetInstalled = false
  private(set) var parakeetDownloadFraction: Double?
  private(set) var engineChoice: EngineID = .apple
  private let inserter = MacOSTextInserter()
  private let permissions = PermissionManager()
  private let capture = MicrophoneCapture()
  private var hotkeyMonitor: GlobalHotkeyMonitor?
  private var indicatorPanel: IndicatorPanelController?
  private var frameCollector: Task<Void, Never>?
  private var elapsedTimer: Task<Void, Never>?
  private var audioBuffer = DictationAudioBuffer()
  private var toggleSessionActive = false
  /// Safety valve: a forgotten toggle session must not record forever.
  private var toggleAutoStop: Task<Void, Never>?
  private static let toggleMaximumDuration: Duration = .seconds(600)
  private var lastOutcome: DictationOutcome?

  func start() async {
    indicatorPanel = IndicatorPanelController(model: indicator)
    do {
      let paths = try ApplicationPaths.production()
      let store = try await FlowStore.open(at: paths.database)
      self.store = store

      self.paths = paths
      let apple = AppleSpeechEngine()
      await apple.resolveLocale()
      appleEngine = apple
      let parakeet = ParakeetEngine(modelsBaseDirectory: paths.models)
      parakeetEngine = parakeet
      parakeetInstalled = await parakeet.isInstalled
      if let saved = try? await store.setting(forKey: "engine"),
        let choice = EngineID(rawValue: saved), choice == .parakeet, parakeetInstalled
      {
        engineChoice = .parakeet
      }

      let controller = makeController(store: store, scratch: paths.scratch)
      self.controller = controller
      await attachObservers(to: controller)

      installHotkeys()

      // Pre-warm off the critical path so cold launch → ready stays fast.
      Task.detached(priority: .utility) {
        await controller.prewarm()
      }
      await refreshRecentDictations()
    } catch {
      Self.log.error("startup failed: \(error)")
      indicator.display = .error("Startup failed: \(error.localizedDescription)")
      indicatorPanel?.show()
    }
  }

  // MARK: - Engines

  private func makeController(store: FlowStore, scratch: URL) -> DictationController {
    let inserter = self.inserter
    let provider = transcriptionProvider()
    return DictationController(
      engine: provider,
      cleaner: TranscriptCleaner(),
      store: store,
      scratchDirectory: scratch,
      dependencies: DictationDependencies(
        captureTarget: { await MainActor.run { inserter.captureTarget() } },
        clearTarget: { await MainActor.run { inserter.clearTarget() } },
        insert: { text in
          try await inserter.insert(text, replacingSelection: false, pressEnter: false)
        },
        copyToClipboard: { text in
          await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
          }
        }))
  }

  private func transcriptionProvider() -> any TranscriptionProviding {
    guard let appleEngine else { fatalError("engines built before provider") }
    if engineChoice == .parakeet, let parakeetEngine {
      return EngineCoordinator(primary: parakeetEngine, fallback: appleEngine)
    }
    return appleEngine
  }

  private func attachObservers(to controller: DictationController) async {
    await controller.setStateObserver { [weak self] state in
      Task { @MainActor in self?.handleState(state) }
    }
    await controller.setOutcomeObserver { [weak self] outcome in
      Task { @MainActor in self?.lastOutcome = outcome }
    }
  }

  /// Explicit, user-invoked download — the only network-capable action.
  func installParakeet() {
    guard let parakeetEngine, parakeetDownloadFraction == nil else { return }
    parakeetDownloadFraction = 0
    indicator.display = .downloading(percent: 0)
    indicatorPanel?.show()
    Task {
      do {
        try await parakeetEngine.install { [weak self] fraction in
          Task { @MainActor in
            self?.parakeetDownloadFraction = fraction
            self?.indicator.display = .downloading(percent: Int(fraction * 100))
          }
        }
        parakeetInstalled = true
        parakeetDownloadFraction = nil
        await setEngine(.parakeet)
        indicator.display = .success(words: 0)
        scheduleIndicatorHide(after: .seconds(1.2))
      } catch {
        Self.log.error("Parakeet install failed: \(error)")
        parakeetDownloadFraction = nil
        indicator.display = .error("Parakeet download failed")
        scheduleIndicatorHide(after: .seconds(2.5))
      }
    }
  }

  func setEngine(_ choice: EngineID) async {
    guard engineChoice != choice else { return }
    engineChoice = choice
    try? await store?.setSetting(choice.rawValue, forKey: "engine")
    guard let store, let paths else { return }
    let controller = makeController(store: store, scratch: paths.scratch)
    self.controller = controller
    await attachObservers(to: controller)
    Task.detached(priority: .utility) { await controller.prewarm() }
  }

  // MARK: - Hotkeys

  private func installHotkeys() {
    let monitor = GlobalHotkeyMonitor(
      configuration: .default,
      onHoldDown: { [weak self] in self?.beginDictation(mode: .hold) },
      onHoldUp: { [weak self] in self?.endDictation() },
      onToggle: { [weak self] in self?.toggleDictation() },
      onCancel: { [weak self] in self?.cancelDictation() },
      onChordAbort: { [weak self] in self?.cancelDictation() })
    monitor.install()
    hotkeyMonitor = monitor
  }

  func beginDictation(mode: DictationMode) {
    guard permissions.microphoneAuthorization == .authorized else {
      Task { _ = await permissions.requestMicrophonePermission() }
      return
    }
    guard let controller else { return }
    // The indicator appears immediately on the hotkey edge — the <100 ms
    // budget — before any async work.
    indicator.display = .recording(mode: mode == .hold ? .hold : .toggle)
    indicator.audioLevel = 0
    indicator.elapsedSeconds = 0
    indicatorPanel?.show()

    Task {
      guard await controller.startDictation(mode: mode) else {
        await MainActor.run { self.indicator.display = .hidden }
        indicatorPanel?.hide()
        return
      }
      await MainActor.run { self.startCapture() }
    }
  }

  func endDictation() {
    toggleAutoStop?.cancel()
    toggleAutoStop = nil
    toggleSessionActive = false
    stopElapsedTimer()
    capture.stop()
    // The frame collector drains the stream to completion, then hands the
    // frames to the controller.
  }

  private func toggleDictation() {
    if toggleSessionActive {
      endDictation()
    } else {
      toggleSessionActive = true
      beginDictation(mode: .toggle)
      toggleAutoStop?.cancel()
      toggleAutoStop = Task { [weak self] in
        try? await Task.sleep(for: Self.toggleMaximumDuration)
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.endDictation() }
      }
    }
  }

  func cancelDictation() {
    guard let controller else { return }
    toggleAutoStop?.cancel()
    toggleSessionActive = false
    stopElapsedTimer()
    capture.stop()
    frameCollector?.cancel()
    frameCollector = nil
    Task { await controller.cancelDictation() }
  }

  // MARK: - Capture plumbing

  private func startCapture() {
    guard let controller else { return }
    audioBuffer = DictationAudioBuffer()
    let buffer = audioBuffer
    do {
      let frames = try capture.start { [weak self] level in
        self?.indicator.audioLevel = level
        Task { await controller.updateAudioLevel(level) }
      }
      startElapsedTimer()
      frameCollector = Task {
        for await frame in frames {
          await buffer.append(frame)
        }
        // Stream finished — capture stopped. Hand everything over unless the
        // dictation was cancelled meanwhile.
        guard !Task.isCancelled else { return }
        let collected = await buffer.frames()
        await controller.finishRecording(frames: collected)
        await self.refreshRecentDictations()
      }
    } catch {
      Self.log.error("mic capture failed: \(error)")
      Task { await controller.cancelDictation() }
      indicator.display = .error("Microphone unavailable")
      scheduleIndicatorHide(after: .seconds(2.5))
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

  // MARK: - State → indicator

  private func handleState(_ state: DictationState) {
    switch state {
    case .idle:
      menuBarState = .idle
    case .recording:
      menuBarState = .recording
    case .processing, .inserting:
      menuBarState = .processing
      indicator.display = .processing
    case .completed:
      menuBarState = .idle
      if let outcome = lastOutcome, outcome.insertionMethod == .historyOnly {
        indicator.display = .clipboardFallback
        scheduleIndicatorHide(after: .seconds(2.5))
      } else {
        indicator.display = .success(words: lastOutcome?.wordCount ?? 0)
        scheduleIndicatorHide(after: .seconds(1.2))
      }
      lastOutcome = nil
    case .cancelled:
      menuBarState = .idle
      indicator.display = .hidden
      indicatorPanel?.hide()
    case .failed(let message):
      menuBarState = .idle
      indicator.display = .error(message)
      scheduleIndicatorHide(after: .seconds(2.5))
      lastOutcome = nil
    }
  }

  private func scheduleIndicatorHide(after delay: Duration) {
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self else { return }
      // A new dictation may have started while the confirmation lingered.
      switch self.indicator.display {
      case .recording, .processing, .downloading:
        return
      default:
        self.indicator.display = .hidden
        self.indicatorPanel?.hide()
      }
    }
  }

  // MARK: - Menu bar data

  func refreshRecentDictations() async {
    guard let store else { return }
    recentDictations = (try? await store.recentDictations(limit: 5)) ?? []
  }

  func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
