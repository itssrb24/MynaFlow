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

      let engine = AppleSpeechEngine()
      await engine.resolveLocale()

      let inserter = self.inserter
      let controller = DictationController(
        engine: engine,
        cleaner: TranscriptCleaner(),
        store: store,
        scratchDirectory: paths.scratch,
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
      self.controller = controller

      await controller.setStateObserver { [weak self] state in
        Task { @MainActor in self?.handleState(state) }
      }
      await controller.setOutcomeObserver { [weak self] outcome in
        Task { @MainActor in self?.lastOutcome = outcome }
      }

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
      case .recording, .processing:
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
