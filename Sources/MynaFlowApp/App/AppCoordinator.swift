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
  // Polish / language model
  private var languageProvider: LanguageModelProvider?
  private var modelManager: LocalModelManager?
  private(set) var polishModel: ModelDescriptor?
  private(set) var polishModelInstalled = false
  private(set) var polishDownloadFraction: Double?
  private(set) var polishAvailable = false
  private var polishInFlight = false
  // Main window state
  private(set) var styles: [Style] = []
  private(set) var hotkeyConfiguration: HotkeyConfiguration = .default
  private(set) var inputDevices: [AudioInputDevice] = []
  private(set) var selectedInputUID: String?
  private(set) var cleanupEnabled = true
  private(set) var modelStates: [String: ModelInstallState] = [:]
  let hardware = HardwareProfile.current()
  private(set) var vocabulary: [VocabularyTerm] = []
  private(set) var corrections: [CorrectionRecord] = []
  private(set) var typingWPM: Double = 40
  private let correctionWatcher = CorrectionWatcher()
  /// The app that was frontmost before our window took focus — where
  /// "Re-insert" should land.
  private var lastExternalApp: NSRunningApplication?
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

      if let json = try? await store.setting(forKey: "hotkeys"),
        let decoded = try? JSONDecoder().decode(HotkeyConfiguration.self, from: Data(json.utf8))
      {
        hotkeyConfiguration = decoded
      }
      selectedInputUID = (try? await store.setting(forKey: "input_device_uid"))
        .flatMap { $0.isEmpty ? nil : $0 }
      capture.preferredDeviceUID = selectedInputUID
      cleanupEnabled = (try? await store.setting(forKey: "cleanup_enabled")) != "0"
      if let wpm = try? await store.setting(forKey: "typing_wpm"), let value = Double(wpm), value > 0 {
        typingWPM = value
      }
      await refreshVocabulary()

      let controller = makeController(store: store, scratch: paths.scratch)
      self.controller = controller
      await controller.setCleanupEnabled(cleanupEnabled)
      await attachObservers(to: controller)
      await refreshStyles()

      installHotkeys()
      await buildLanguageProvider(paths: paths, store: store)

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
    let controller = DictationController(
      engine: provider,
      cleaner: TranscriptCleaner(protectedTerms: vocabulary.map(\.term)),
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
    Task {
      await controller.setHintsProvider {
        let terms = (try? await store.vocabularyTerms().map(\.term)) ?? []
        return BiasTerms.sanitize(terms)
      }
    }
    return controller
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
      Task { @MainActor in
        self?.lastOutcome = outcome
        self?.watchForCorrection(outcome)
      }
    }
  }

  /// After a cursor insertion, watch the field briefly for the user's edits.
  private func watchForCorrection(_ outcome: DictationOutcome) {
    guard outcome.insertionMethod == .ax, outcome.failureMessage == nil, let store else { return }
    correctionWatcher.watch(insertedText: outcome.text, dictationID: outcome.dictationID) { pair in
      try? await store.logCorrection(pair, dictationID: outcome.dictationID)
    }
  }

  // MARK: - Insights + vocabulary

  func loadInsights(period: InsightsPeriod) async -> Insights {
    guard let store else {
      return InsightsAggregator.aggregate([], typingWPM: typingWPM, period: period)
    }
    let records = (try? await store.searchDictations(HistoryQuery(), limit: 200_000)) ?? []
    return InsightsAggregator.aggregate(records, typingWPM: typingWPM, period: period)
  }

  func setTypingWPM(_ value: Double) {
    typingWPM = value
    Task { try? await store?.setSetting("\(Int(value))", forKey: "typing_wpm") }
  }

  func refreshVocabulary() async {
    guard let store else { return }
    vocabulary = (try? await store.vocabularyTerms()) ?? []
    corrections = (try? await store.pendingCorrections()) ?? []
  }

  func addVocabularyTerm(_ term: String) async {
    try? await store?.addVocabularyTerm(term, source: .manual)
    await refreshVocabulary()
    await rebuildControllerForVocabulary()
  }

  func removeVocabularyTerm(_ term: String) async {
    try? await store?.removeVocabularyTerm(term)
    await refreshVocabulary()
    await rebuildControllerForVocabulary()
  }

  func acceptCorrection(_ correction: CorrectionRecord) async {
    for term in CorrectionDetector.candidateTerms(from: correction.pair) {
      try? await store?.addVocabularyTerm(term, source: .promoted)
    }
    try? await store?.resolveCorrection(id: correction.id, status: .accepted)
    await refreshVocabulary()
    await rebuildControllerForVocabulary()
  }

  func dismissCorrection(_ correction: CorrectionRecord) async {
    try? await store?.resolveCorrection(id: correction.id, status: .dismissed)
    await refreshVocabulary()
  }

  /// The cleaner's protected-term set is baked in at construction, so a
  /// vocabulary change rebuilds the controller (cheap; no engine reload).
  private func rebuildControllerForVocabulary() async {
    guard let store, let paths else { return }
    let controller = makeController(store: store, scratch: paths.scratch)
    await controller.setCleanupEnabled(cleanupEnabled)
    self.controller = controller
    await attachObservers(to: controller)
  }

  /// Explicit, user-invoked download — the only network-capable action.
  func installParakeet() {
    guard let parakeetEngine, parakeetDownloadFraction == nil else { return }
    parakeetDownloadFraction = 0
    indicator.display = .downloading(what: "Parakeet", percent: 0)
    indicatorPanel?.show()
    Task {
      do {
        try await parakeetEngine.install { [weak self] fraction in
          Task { @MainActor in
            self?.parakeetDownloadFraction = fraction
            self?.indicator.display = .downloading(what: "Parakeet", percent: Int(fraction * 100))
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

  // MARK: - Polish / language model

  /// Builds the provider once. LlamaServerHost spawns nothing until the first
  /// polish, so this costs no model memory at startup.
  private func buildLanguageProvider(paths: ApplicationPaths, store: FlowStore) async {
    let manager = LocalModelManager(modelsDirectory: paths.models)
    modelManager = manager

    // The model in use: saved choice, else the hardware-fit recommendation.
    let saved = try? await store.setting(forKey: "language_model")
    let descriptor =
      saved.flatMap { DefaultModelCatalog.descriptor(id: $0) }
      ?? SetupAdvisor.largestRunnableLanguageModel(on: .current())
    guard let descriptor else { return }
    polishModel = descriptor
    let modelURL = await manager.modelURL(for: descriptor)
    polishModelInstalled = FileManager.default.fileExists(atPath: modelURL.path)

    guard let serverURL = Self.runtimeExecutable(named: "llama-server", paths: paths),
      let cliURL = Self.runtimeExecutable(named: "llama-cli", paths: paths)
    else {
      Self.log.warning("llama runtimes not found; polish disabled")
      return
    }
    let host = LlamaServerHost(
      configuration: LlamaServerHost.Configuration(
        executableURL: serverURL,
        modelURL: modelURL,
        modelIdentifier: descriptor.id,
        idleTimeout: 300,
        diagnosticsDirectory: paths.diagnostics))
    languageProvider = LanguageModelProvider(
      host: host, cliExecutableURL: cliURL, modelURL: modelURL)
    polishAvailable = polishModelInstalled
  }

  /// Release builds only run the Gatekeeper-validated binary sealed inside
  /// the signed bundle. The Application Support fallback is a debug-only
  /// convenience — executing a binary from a user-writable directory must
  /// never happen in a shipped build.
  private static func runtimeExecutable(named name: String, paths: ApplicationPaths) -> URL? {
    if let resources = Bundle.main.resourceURL {
      let bundled = resources.appendingPathComponent("Runtimes/\(name)")
      if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    }
    #if DEBUG
      let fallback = paths.runtimes.appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: fallback.path) { return fallback }
    #endif
    return nil
  }

  /// Explicit, user-invoked language model download (menu bar shortcut for
  /// the recommended model).
  func installPolishModel() {
    guard let descriptor = polishModel else { return }
    installModel(descriptor)
  }

  func installModel(_ descriptor: ModelDescriptor) {
    guard let modelManager, polishDownloadFraction == nil else { return }
    polishDownloadFraction = 0
    indicator.display = .downloading(what: descriptor.displayName, percent: 0)
    indicatorPanel?.show()
    Task {
      await modelManager.setProgressObserver { [weak self] id, state in
        Task { @MainActor in
          self?.modelStates[id] = state
          guard case .downloading(let received, let total) = state, total > 0 else { return }
          let fraction = Double(received) / Double(total)
          self?.polishDownloadFraction = fraction
          self?.indicator.display = .downloading(
            what: descriptor.displayName, percent: Int(fraction * 100))
        }
      }
      do {
        try await modelManager.install(descriptor)
        polishDownloadFraction = nil
        await selectPolishModel(descriptor)
        indicator.display = .success(words: 0)
        scheduleIndicatorHide(after: .seconds(1.2))
      } catch {
        Self.log.error("model install failed: \(error)")
        polishDownloadFraction = nil
        indicator.display = .error("Model download failed")
        scheduleIndicatorHide(after: .seconds(2.5))
      }
      await refreshModelStates()
    }
  }

  func cancelModelInstall() {
    Task { await modelManager?.cancelActiveInstall() }
  }

  func refreshModelStates() async {
    guard let modelManager else { return }
    var states: [String: ModelInstallState] = [:]
    for descriptor in DefaultModelCatalog.all {
      states[descriptor.id] = await modelManager.state(for: descriptor)
    }
    modelStates = states
    if let polishModel {
      polishModelInstalled = states[polishModel.id] == .installed
      polishAvailable = polishModelInstalled && languageProvider != nil
    }
  }

  /// Switch the polish model; the warm server re-spawns lazily with it.
  func selectPolishModel(_ descriptor: ModelDescriptor) async {
    guard let modelManager else { return }
    polishModel = descriptor
    let modelURL = await modelManager.modelURL(for: descriptor)
    await languageProvider?.updateModel(modelURL: modelURL, modelIdentifier: descriptor.id)
    try? await store?.setSetting(descriptor.id, forKey: "language_model")
    await refreshModelStates()
  }

  func removeModel(_ descriptor: ModelDescriptor) async {
    guard let modelManager else { return }
    if polishModel?.id == descriptor.id { await languageProvider?.stop() }
    try? await modelManager.remove(descriptor)
    await refreshModelStates()
  }

  func removeParakeet() {
    guard let parakeetEngine else { return }
    Task {
      if engineChoice == .parakeet { await setEngine(.apple) }
      try? await parakeetEngine.remove()
      parakeetInstalled = false
    }
  }

  // MARK: - Main window

  func showMainWindow(open: (String) -> Void) {
    // Remember where the user was so Re-insert can go back there.
    lastExternalApp = NSWorkspace.shared.frontmostApplication
    open("main")
    NSApp.activate(ignoringOtherApps: true)
  }

  func searchHistory(_ query: HistoryQuery, limit: Int) async -> [DictationRecord] {
    guard let store else { return [] }
    return (try? await store.searchDictations(query, limit: limit)) ?? []
  }

  func historyApps() async -> [String] {
    guard let store else { return [] }
    return (try? await store.distinctTargetApps()) ?? []
  }

  func deleteHistory(_ range: DeletionRange) async {
    try? await store?.deleteDictations(since: range.cutoff())
    await refreshRecentDictations()
  }

  func deleteHistoryEntry(_ id: UUID) async {
    try? await store?.deleteDictation(id: id)
    await refreshRecentDictations()
  }

  /// Puts the entry back at the cursor of the app the user came from.
  func reinsert(_ record: DictationRecord) async {
    guard let target = lastExternalApp, !target.isTerminated else {
      copyToClipboard(record.finalText)
      indicator.display = .clipboardFallback
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(2))
      return
    }
    NSApp.hide(nil)
    target.activate()
    try? await Task.sleep(for: .milliseconds(300))
    inserter.captureTarget()
    let result = try? await inserter.insert(record.finalText, replacingSelection: false, pressEnter: false)
    inserter.clearTarget()
    switch result {
    case .inserted, .replacedSelection, .pastedFromClipboard:
      indicator.display = .success(words: record.wordCount)
    case .blockedSecureField:
      indicator.display = .error("Blocked: password field")
    default:
      indicator.display = .clipboardFallback
    }
    indicatorPanel?.show()
    scheduleIndicatorHide(after: .seconds(1.5))
  }

  /// Rewrites a history entry in a style; updates final_text, never cleaned_text.
  func repolish(_ record: DictationRecord, style: Style) async {
    guard let languageProvider, let store else { return }
    let engine = PolishEngine(
      model: languageProvider,
      readSelection: { record.finalText },
      replaceSelection: { text in
        try await store.updateFinalText(text, style: style.name, forDictation: record.id)
        return .replacedSelection
      })
    let outcome = await engine.polish(style: style)
    if case .failed(let message) = outcome {
      indicator.display = .error(message)
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(2.5))
    }
    await refreshRecentDictations()
  }

  // MARK: Styles

  func refreshStyles() async {
    guard let store else { return }
    styles = (try? await store.styles()) ?? []
  }

  /// Saves a style; a slot can hold one style, so any other holder is unassigned.
  func saveStyle(_ style: Style) async throws {
    guard let store else { return }
    if let slot = style.hotkeySlot {
      for other in styles where other.id != style.id && other.hotkeySlot == slot {
        var freed = other
        freed.hotkeySlot = nil
        try await store.saveStyle(freed)
      }
    }
    try await store.saveStyle(style)
    await refreshStyles()
  }

  func deleteStyle(id: UUID) async {
    try? await store?.deleteStyle(id: id)
    await refreshStyles()
  }

  // MARK: Hotkeys

  func updateHotkey(_ action: HotkeyAction, shortcut: HotkeyShortcut?) {
    hotkeyConfiguration[action] = shortcut
    hotkeyMonitor?.update(configuration: hotkeyConfiguration)
    if let data = try? JSONEncoder().encode(hotkeyConfiguration),
      let json = String(data: data, encoding: .utf8)
    {
      Task { try? await store?.setSetting(json, forKey: "hotkeys") }
    }
  }

  // MARK: Audio + cleanup

  func refreshInputDevices() {
    inputDevices = AudioDevices.inputs()
  }

  func selectInputDevice(uid: String?) {
    selectedInputUID = uid
    capture.preferredDeviceUID = uid
    Task {
      if let uid {
        try? await store?.setSetting(uid, forKey: "input_device_uid")
      } else {
        try? await store?.setSetting("", forKey: "input_device_uid")
      }
    }
  }

  func setCleanupEnabled(_ enabled: Bool) {
    cleanupEnabled = enabled
    Task {
      await controller?.setCleanupEnabled(enabled)
      try? await store?.setSetting(enabled ? "1" : "0", forKey: "cleanup_enabled")
    }
  }

  /// Style hotkey pressed: polish the current selection in place.
  func polishSelection(action: HotkeyAction) {
    guard let slot = action.styleSlot else { return }
    guard !polishInFlight else { return }
    guard let languageProvider, polishModelInstalled else {
      indicator.display = .error("Polish needs the language model — install it from the menu bar")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(2.5))
      return
    }
    polishInFlight = true
    Task {
      defer { polishInFlight = false }
      guard let style = try? await store?.style(forSlot: slot) else {
        indicator.display = .error("No style bound to that key")
        indicatorPanel?.show()
        scheduleIndicatorHide(after: .seconds(2))
        return
      }
      indicator.display = .polishing(style: style.name)
      indicatorPanel?.show()

      let inserter = self.inserter
      let engine = PolishEngine(
        model: languageProvider,
        readSelection: { await MainActor.run { SelectionReader.selectedText() } },
        replaceSelection: { text in
          await MainActor.run { inserter.captureTarget() }
          return try await inserter.insert(text, replacingSelection: true, pressEnter: false)
        })
      let outcome = await engine.polish(style: style)
      switch outcome {
      case .replaced:
        indicator.display = .success(words: 0)
        scheduleIndicatorHide(after: .seconds(1.2))
      case .noSelection:
        indicator.display = .error("Select some text first")
        scheduleIndicatorHide(after: .seconds(2))
      case .failed(let message):
        indicator.display = .error(message)
        scheduleIndicatorHide(after: .seconds(2.5))
      }
    }
  }

  // MARK: - Hotkeys

  private func installHotkeys() {
    let monitor = GlobalHotkeyMonitor(
      configuration: hotkeyConfiguration,
      onHoldDown: { [weak self] in self?.beginDictation(mode: .hold) },
      onHoldUp: { [weak self] in self?.endDictation() },
      onToggle: { [weak self] in self?.toggleDictation() },
      onCancel: { [weak self] in self?.cancelDictation() },
      onChordAbort: { [weak self] in self?.cancelDictation() },
      onStyle: { [weak self] action in self?.polishSelection(action: action) })
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
