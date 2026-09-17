import AppKit
import MynaFlowCore
import SwiftUI
import os

/// Wires the whole Phase 1 loop together: hotkeys → capture → controller →
/// indicator. Owned by the app for its lifetime.
@MainActor
@Observable
final class AppCoordinator {
  nonisolated private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "app")

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
  private(set) var boostingInstalled = false
  private(set) var boostingInstalling = false
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
  private var activePolish: PolishEngine?
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
  // Learning layer
  private(set) var learningEnabled = false
  private(set) var suggestedRules: [StoredLearnedRule] = []
  private(set) var approvedRules: [StoredLearnedRule] = []
  private let correctionWatcher = CorrectionWatcher()
  /// The app that was frontmost before our window took focus — where
  /// "Re-insert" should land.
  private var lastExternalApp: NSRunningApplication?
  private let inserter = MacOSTextInserter()
  private let permissions = PermissionManager()
  private let capture = MicrophoneCapture()
  private var hotkeyMonitor: GlobalHotkeyMonitor?
  private var indicatorPanel: IndicatorPanelController?
  private var lastOutcome: DictationOutcome?
  /// Owns start/stop/cancel/capture; see DictationSessionPolicy for the rules.
  private var session: DictationSession?
  private var controllerState: DictationState = .idle
  /// Set when startup had to move a corrupt history database aside.
  private(set) var recoveredDatabaseURL: URL?

  private let launchedAt = Date()

  func start() async {
    indicatorPanel = IndicatorPanelController(model: indicator)
    do {
      let paths = try ApplicationPaths.production()
      let store: FlowStore
      do {
        store = try await FlowStore.open(at: paths.database)
      } catch {
        // Move the unopenable file aside and start fresh: dictation must
        // keep working, and nothing is deleted.
        Self.log.error("history database failed to open: \(error); moving aside")
        let aside = try StartupRecovery.moveAside(database: paths.database)
        store = try await FlowStore.open(at: paths.database)
        recoveredDatabaseURL = aside
      }
      self.store = store

      self.paths = paths
      let apple = AppleSpeechEngine()
      await apple.resolveLocale()
      appleEngine = apple
      let parakeet = ParakeetEngine(modelsBaseDirectory: paths.models)
      parakeetEngine = parakeet
      parakeetInstalled = await parakeet.isInstalled
      boostingInstalled = await parakeet.isBoostingInstalled
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
      learningEnabled = (try? await store.setting(forKey: "learning_enabled")) == "1"
      await refreshLearnedRules()

      let controller = makeController(store: store, scratch: paths.scratch)
      await controller.setCleanupEnabled(cleanupEnabled)
      session = makeSession(controller: controller, scratch: paths.scratch)
      await installController(controller)
      await refreshStyles()

      installHotkeys()
      installSleepWakeHandling()
      await buildLanguageProvider(paths: paths, store: store)

      // Pre-warm off the critical path so cold launch → ready stays fast.
      Task.detached(priority: .utility) {
        await controller.prewarm()
      }
      await refreshRecentDictations()
      Task { await self.runLearner() }
      refreshPermissions()
      needsOnboarding = (try? await store.setting(forKey: "onboarded")) == nil
      let readyMs = Int(Date().timeIntervalSince(self.launchedAt) * 1000)
      Self.log.info("ready in \(readyMs) ms")
    } catch {
      Self.log.error("startup failed: \(error)")
      indicator.display = .error("Startup failed: \(error.localizedDescription)")
      indicatorPanel?.show()
    }
  }

  /// App quit: stop the model server (otherwise it outlives us holding
  /// gigabytes) and close the database cleanly.
  func shutdown() async {
    session?.handle(.cancel)
    await languageProvider?.stop()
    await store?.close()
  }

  /// Installed-ness is a claim about the filesystem, so re-check it before
  /// it matters (menu open, dictation, polish) rather than trusting launch.
  func refreshInstalledFlags() async {
    if let parakeetEngine {
      parakeetInstalled = await parakeetEngine.isInstalled
      boostingInstalled = await parakeetEngine.isBoostingInstalled
      if engineChoice == .parakeet, !parakeetInstalled {
        await setEngine(.apple)
      }
    }
    if let modelManager, let polishModel {
      polishModelInstalled = await modelManager.state(for: polishModel) == .installed
      polishAvailable = polishModelInstalled && languageProvider != nil
    }
  }

  func revealRecoveredDatabase() {
    guard let recoveredDatabaseURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([recoveredDatabaseURL])
  }

  // MARK: - Engines

  private func makeController(store: FlowStore, scratch: URL) -> DictationController {
    let inserter = self.inserter
    let provider = transcriptionProvider()
    let controller = DictationController(
      engine: provider,
      cleaner: TranscriptCleaner(
        protectedTerms: vocabulary.map(\.term),
        learnedRules: LearnedRules(approved: approvedRules.map(\.rule), enabled: learningEnabled)),
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

  /// Events flow through one stream consumed by one main-actor task, so the
  /// order the controller emitted them in is the order the UI sees them.
  private var eventPump: Task<Void, Never>?

  private func attachObservers(to controller: DictationController) async {
    eventPump?.cancel()
    let (stream, continuation) = AsyncStream<DictationControllerEvent>.makeStream()
    await controller.setEventObserver { event in continuation.yield(event) }
    eventPump = Task { @MainActor [weak self] in
      for await event in stream {
        guard let self else { return }
        switch event {
        case .state(let state):
          self.handleState(state)
        case .outcome(let outcome):
          self.lastOutcome = outcome
          if outcome.insertionMethod == .ax, outcome.failureMessage == nil {
            self.lastInsertionAt = Date()
          }
          self.watchForCorrection(outcome)
        }
      }
    }
  }

  /// After a cursor insertion, watch the field briefly for the user's edits.
  private func watchForCorrection(_ outcome: DictationOutcome) {
    guard outcome.insertionMethod == .ax, outcome.failureMessage == nil, let store else { return }
    correctionWatcher.watch(insertedText: outcome.text, dictationID: outcome.dictationID) { [weak self] pair in
      do {
        _ = try await store.logCorrection(pair, dictationID: outcome.dictationID)
        await self?.runLearner()
      } catch {
        Self.log.error("correction log failed: \(error)")
      }
    }
  }

  // MARK: - Learning layer

  func refreshLearnedRules() async {
    guard let store else { return }
    suggestedRules = (try? await store.learnedRules(status: .suggested)) ?? []
    approvedRules = (try? await store.learnedRules(status: .approved)) ?? []
  }

  /// Re-derives suggestions from every correction on record. Cheap enough
  /// to run after each logged correction.
  func runLearner() async {
    guard let store else { return }
    let corrections = ((try? await store.allCorrections()) ?? []).map(\.pair)
    let existing = ((try? await store.allLearnedRules()) ?? []).map(\.rule)
    let suggestions = StyleProfileLearner.suggest(
      corrections: corrections, records: [], existing: existing)
    await persist("save suggestions") {
      for rule in suggestions { try await store.upsertSuggestedRule(rule) }
    }
    await refreshLearnedRules()
  }

  func setRuleStatus(_ id: UUID, _ status: LearnedRuleStatus) async {
    await persist("update rule") { try await store?.setRuleStatus(id: id, status: status) }
    await refreshLearnedRules()
    await rebuildControllerForVocabulary()
  }

  func setLearningEnabled(_ enabled: Bool) {
    learningEnabled = enabled
    Task {
      await persist("save learning switch") {
        try await store?.setSetting(enabled ? "1" : "0", forKey: "learning_enabled")
      }
      await rebuildControllerForVocabulary()
    }
  }

  /// Runs a user-initiated store mutation; failures are logged and shown,
  /// never swallowed into a list that silently didn't change.
  private func persist(_ what: String, _ operation: () async throws -> Void) async {
    do {
      try await operation()
    } catch {
      Self.log.error("\(what) failed: \(error)")
      indicator.display = .error("Couldn't \(what): \(error.localizedDescription)")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(3))
    }
  }

  // MARK: - Onboarding

  private(set) var needsOnboarding = false
  private(set) var microphoneGranted = false
  private(set) var accessibilityGranted = false
  private var previewFrames: Task<Void, Never>?

  func refreshPermissions() {
    microphoneGranted = permissions.microphoneAuthorization == .authorized
    accessibilityGranted = permissions.hasAccessibilityPermission
  }

  func requestMicrophone() async {
    _ = await permissions.requestMicrophonePermission()
    refreshPermissions()
  }

  func requestAccessibility() {
    permissions.requestAccessibilityPermission()
    refreshPermissions()
  }

  /// Live meter for the mic step; frames are drained and discarded.
  func startLevelPreview(onLevel: @escaping @MainActor (Float) -> Void) {
    stopLevelPreview()
    guard let stream = try? capture.start(levelChanged: onLevel) else { return }
    previewFrames = Task { for await _ in stream {} }
  }

  func stopLevelPreview() {
    previewFrames?.cancel()
    previewFrames = nil
    capture.stop()
  }

  /// Inserts a sentence into whatever field is focused (the onboarding field).
  func testInsertion() async -> String {
    inserter.captureTarget()
    let result = try? await inserter.insert(
      "Myna Flow can place text here.", replacingSelection: false, pressEnter: false)
    inserter.clearTarget()
    switch result {
    case .inserted, .replacedSelection, .pastedFromClipboard: return "Inserted — Accessibility works."
    case .noFocusedField: return "Click the field first, then press Test."
    default: return "Insertion did not land: \(inserter.lastInsertionDiagnostics)"
    }
  }

  func completeOnboarding() {
    needsOnboarding = false
    Task { try? await store?.setSetting("1", forKey: "onboarded") }
  }

  // MARK: - Insights + vocabulary

  func loadInsights(period: InsightsPeriod) async -> Insights {
    guard let store else {
      return InsightsAggregator.aggregate([], typingWPM: typingWPM, period: period)
    }
    do {
      return try await store.insights(typingWPM: typingWPM, period: period)
    } catch {
      Self.log.error("insights failed: \(error)")
      return InsightsAggregator.aggregate([], typingWPM: typingWPM, period: period)
    }
  }

  func setTypingWPM(_ value: Double) {
    typingWPM = value
    Task { await persist("save typing speed") { try await store?.setSetting("\(Int(value))", forKey: "typing_wpm") } }
  }

  func refreshVocabulary() async {
    guard let store else { return }
    vocabulary = (try? await store.vocabularyTerms()) ?? []
    corrections = (try? await store.pendingCorrections()) ?? []
  }

  func addVocabularyTerm(_ term: String) async {
    await persist("add term") { try await store?.addVocabularyTerm(term, source: .manual) }
    await refreshVocabulary()
    await rebuildControllerForVocabulary()
  }

  func removeVocabularyTerm(_ term: String) async {
    await persist("remove term") { try await store?.removeVocabularyTerm(term) }
    await refreshVocabulary()
    await rebuildControllerForVocabulary()
  }

  func acceptCorrection(_ correction: CorrectionRecord) async {
    await persist("add term") {
      for term in CorrectionDetector.candidateTerms(from: correction.pair) {
        try await store?.addVocabularyTerm(term, source: .promoted)
      }
      try await store?.resolveCorrection(id: correction.id, status: .accepted)
    }
    await refreshVocabulary()
    await rebuildControllerForVocabulary()
  }

  func dismissCorrection(_ correction: CorrectionRecord) async {
    await persist("dismiss suggestion") { try await store?.resolveCorrection(id: correction.id, status: .dismissed) }
    await refreshVocabulary()
  }

  /// The cleaner's protected-term set is baked in at construction, so a
  /// vocabulary change rebuilds the controller (cheap; no engine reload).
  private func rebuildControllerForVocabulary() async {
    guard let store, let paths else { return }
    let controller = makeController(store: store, scratch: paths.scratch)
    await controller.setCleanupEnabled(cleanupEnabled)
    await installController(controller)
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
        indicator.display = .success(words: 0, note: nil)
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
    await controller.setCleanupEnabled(cleanupEnabled)
    await installController(controller)
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
    let provider = LanguageModelProvider(
      host: host, cliExecutableURL: cliURL, modelURL: modelURL)
    await provider.setFallbackObserver { [weak self] in
      Task { @MainActor in
        guard let self, self.polishInFlight else { return }
        self.indicator.display = .polishing(style: "retrying via fallback…")
      }
    }
    languageProvider = provider
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
        indicator.display = .success(words: 0, note: nil)
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
    await persist("remove model") { try await modelManager.remove(descriptor) }
    await refreshModelStates()
  }

  /// Explicit download of the CTC models that let Parakeet use the vocabulary.
  func installBoosting() {
    guard let parakeetEngine, parakeetInstalled, !boostingInstalling else { return }
    boostingInstalling = true
    indicator.display = .downloading(what: "vocabulary boosting", percent: 0)
    indicatorPanel?.show()
    Task {
      defer { boostingInstalling = false }
      do {
        try await parakeetEngine.installBoosting()
        boostingInstalled = true
        indicator.display = .success(words: 0, note: nil)
        scheduleIndicatorHide(after: .seconds(1.2))
      } catch {
        Self.log.error("boosting install failed: \(error)")
        indicator.display = .error("Vocabulary boosting download failed")
        scheduleIndicatorHide(after: .seconds(2.5))
      }
    }
  }

  func removeBoosting() {
    guard let parakeetEngine else { return }
    Task {
      await persist("remove vocabulary boosting") {
        try await parakeetEngine.removeBoosting()
        boostingInstalled = false
      }
    }
  }

  func removeParakeet() {
    guard let parakeetEngine else { return }
    Task {
      if engineChoice == .parakeet { await setEngine(.apple) }
      await persist("remove Parakeet") {
        try await parakeetEngine.remove()
        parakeetInstalled = false
      }
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
    do {
      return try await store.searchDictations(query, limit: limit)
    } catch {
      Self.log.error("history load failed: \(error)")
      indicator.display = .error("Couldn't load history: \(error.localizedDescription)")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(3))
      return []
    }
  }

  func historyApps() async -> [String] {
    guard let store else { return [] }
    return (try? await store.distinctTargetApps()) ?? []
  }

  func deleteHistory(_ range: DeletionRange) async {
    await persist("delete history") { try await store?.deleteDictations(since: range.cutoff()) }
    await refreshRecentDictations()
  }

  func deleteHistoryEntry(_ id: UUID) async {
    await persist("delete entry") { try await store?.deleteDictation(id: id) }
    await refreshRecentDictations()
  }

  /// From the window: go back to the app the user came from, then insert.
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
    await insertAtCursor(record)
  }

  /// Inserts into whatever is frontmost right now.
  private func insertAtCursor(_ record: DictationRecord) async {
    inserter.captureTarget()
    let result = try? await inserter.insert(record.finalText, replacingSelection: false, pressEnter: false)
    inserter.clearTarget()
    switch result {
    case .inserted, .replacedSelection, .pastedFromClipboard:
      indicator.display = .success(words: record.wordCount, note: nil)
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
    await persist("delete style") { try await store?.deleteStyle(id: id) }
    await refreshStyles()
  }

  // MARK: Hotkeys

  func updateHotkey(_ action: HotkeyAction, shortcut: HotkeyShortcut?) {
    hotkeyConfiguration[action] = shortcut
    hotkeyMonitor?.update(configuration: hotkeyConfiguration)
    if let data = try? JSONEncoder().encode(hotkeyConfiguration),
      let json = String(data: data, encoding: .utf8)
    {
      Task { await persist("save hotkey") { try await store?.setSetting(json, forKey: "hotkeys") } }
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
      await persist("save microphone choice") {
        try await store?.setSetting(uid ?? "", forKey: "input_device_uid")
      }
    }
  }

  func setCleanupEnabled(_ enabled: Bool) {
    cleanupEnabled = enabled
    Task {
      await controller?.setCleanupEnabled(enabled)
      await persist("save cleanup setting") {
        try await store?.setSetting(enabled ? "1" : "0", forKey: "cleanup_enabled")
      }
    }
  }

  /// Style hotkey pressed: polish the current selection in place.
  func polishSelection(action: HotkeyAction) {
    guard let slot = action.styleSlot else { return }
    guard let style = styles.first(where: { $0.hotkeySlot == slot }) else {
      indicator.display = .error("No style bound to that key")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(2))
      return
    }
    polishSelection(style: style)
  }

  /// From the window: return to the app the user came from, then polish
  /// its selection.
  func polishExternalSelection(style: Style) {
    guard let target = lastExternalApp, !target.isTerminated else {
      indicator.display = .error("Switch to the app with the selection first")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(2))
      return
    }
    NSApp.hide(nil)
    target.activate()
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      polishSelection(style: style)
    }
  }

  func polishSelection(style: Style) {
    if polishInFlight {
      // A second press while one is running cancels it rather than queueing.
      if let activePolish { Task { await activePolish.cancel() } }
      return
    }
    Task { await refreshInstalledFlags() }
    guard let languageProvider, polishModelInstalled else {
      indicator.display = .error("Polish needs the language model — install it from the menu bar")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(2.5))
      return
    }
    polishInFlight = true
    Task {
      defer { polishInFlight = false }
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
      activePolish = engine
      defer { activePolish = nil }
      let outcome = await engine.polish(style: style)
      switch outcome {
      case .replaced:
        indicator.display = .success(words: 0, note: nil)
        scheduleIndicatorHide(after: .seconds(1.2))
      case .cancelled:
        indicator.display = .hidden
        indicatorPanel?.hide()
      case .noSelection:
        indicator.display = .error("Select some text first")
        scheduleIndicatorHide(after: .seconds(2))
      case .failed(let message):
        indicator.display = .error(message)
        scheduleIndicatorHide(after: .seconds(2.5))
      }
    }
  }

  // MARK: - Hotkeys + session

  private var sleepObservers: [any NSObjectProtocol] = []

  /// Sleep ends any live dictation with what was captured (audio across a
  /// sleep is garbage); wake re-arms the global monitors, which macOS can
  /// drop across a sleep/lock cycle.
  private func installSleepWakeHandling() {
    let center = NSWorkspace.shared.notificationCenter
    sleepObservers = [
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.session?.isIdle == false else { return }
          self.session?.handle(.deviceLost)
        }
      },
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.hotkeyMonitor?.install() }
      },
    ]
  }

  private func installHotkeys() {
    let monitor = GlobalHotkeyMonitor(
      configuration: hotkeyConfiguration,
      onHoldDown: { [weak self] in self?.session?.handle(.holdDown) },
      onHoldUp: { [weak self] in self?.session?.handle(.holdUp) },
      onToggle: { [weak self] in self?.session?.handle(.togglePressed) },
      onCancel: { [weak self] in self?.session?.handle(.cancel) },
      onChordAbort: { [weak self] in self?.session?.handle(.cancel) },
      onStyle: { [weak self] action in
        switch action {
        case .undoLast: self?.undoLastDictation()
        case .reinsertLast: self?.reinsertLast()
        default: self?.polishSelection(action: action)
        }
      })
    monitor.install()
    hotkeyMonitor = monitor
    indicator.onStopRequested = { [weak self] in self?.session?.handle(.togglePressed) }
  }

  // MARK: - Undo / re-insert

  /// ⌘Z in the app that got the last dictation. Only offered for a short
  /// window after an insertion so a stale press can't undo unrelated work.
  private static let undoWindow: TimeInterval = 90
  private var lastInsertionAt: Date?

  func undoLastDictation() {
    guard let lastInsertionAt, Date().timeIntervalSince(lastInsertionAt) < Self.undoWindow else {
      indicator.display = .error("Nothing recent to undo")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(1.5))
      return
    }
    self.lastInsertionAt = nil
    Task {
      try? await inserter.undo()
      indicator.display = .success(words: 0, note: "Undone")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(1.2))
    }
  }

  /// Puts the most recent dictation at the current cursor (the frontmost
  /// app — the menu bar does not steal focus).
  func reinsertLast() {
    guard let record = recentDictations.first else {
      indicator.display = .error("No dictation to re-insert")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(1.5))
      return
    }
    Task { await insertAtCursor(record) }
  }

  var launchAtLogin: Bool { LaunchAtLogin.isEnabled }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try LaunchAtLogin.setEnabled(enabled)
    } catch {
      Self.log.error("launch at login failed: \(error)")
      indicator.display = .error("Couldn't change launch at login")
      indicatorPanel?.show()
      scheduleIndicatorHide(after: .seconds(2.5))
    }
  }

  private func makeSession(controller: DictationController, scratch: URL) -> DictationSession {
    let session = DictationSession(
      capture: capture, indicator: indicator, indicatorPanel: indicatorPanel,
      permissions: permissions, scratchDirectory: scratch)
    session.replaceController(controller)
    session.isControllerBusy = { [weak self] in
      switch self?.controllerState {
      case .processing, .inserting: true
      default: false
      }
    }
    session.onFinished = { [weak self] in await self?.refreshRecentDictations() }
    session.onError = { [weak self] message in
      self?.indicator.display = .error(message)
      self?.indicatorPanel?.show()
      self?.scheduleIndicatorHide(after: .seconds(2.5))
    }
    return session
  }

  /// Menu bar "Start Dictation": toggle semantics, so it can always be stopped.
  func toggleDictationFromMenu() {
    session?.handle(.menuStart)
  }

  func cancelDictation() {
    session?.handle(.cancel)
    // Esc with nothing recording cancels a polish that is still thinking.
    if let activePolish { Task { await activePolish.cancel() } }
  }

  /// Swaps the dictation controller (engine or rules changed). The session
  /// applies it between dictations, never mid-flight.
  private func installController(_ controller: DictationController) async {
    self.controller = controller
    await attachObservers(to: controller)
    session?.replaceController(controller)
  }

  // MARK: - State → indicator

  private func handleState(_ state: DictationState) {
    controllerState = state
    switch state {
    case .idle:
      menuBarState = .idle
    case .recording:
      menuBarState = .recording
    case .processing, .inserting:
      menuBarState = .processing
      indicator.display = .processing(
        engine: engineChoice == .parakeet && parakeetInstalled ? "Parakeet" : "Apple Speech")
    case .completed:
      menuBarState = .idle
      if let outcome = lastOutcome, outcome.insertionMethod == .historyOnly {
        indicator.display = .clipboardFallback
        scheduleIndicatorHide(after: .seconds(2.5))
      } else {
        // Fallback is a quiet inline note, never an interruption.
        let note = lastOutcome?.fallbackOccurred == true ? "via Apple Speech — Parakeet fell back" : nil
        indicator.display = .success(words: lastOutcome?.wordCount ?? 0, note: note)
        scheduleIndicatorHide(after: note == nil ? .seconds(1.2) : .seconds(2.2))
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
