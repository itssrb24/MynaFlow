import AVFoundation
import Foundation
import Speech

/// The default transcriber. macOS supplies it, so Myna Flow ships no speech
/// model at all: `SpeechAnalyzer` runs on the Neural Engine, is maintained by
/// Apple, and accepts vocabulary biasing.
///
/// Ported from Myna's `SystemSpeechRecognizer`, minus the meeting machinery
/// (utterance timing runs, the multi-session warm-up arbiter): Flow has a
/// single dictation path, so there is nothing to arbitrate.
public actor AppleSpeechEngine: SpeechEngine {
  public nonisolated let id: EngineID = .apple

  /// The locale in use, resolved from the Mac's own language settings.
  public private(set) var localeIdentifier: String = SpeechLocaleResolver.fallbackIdentifier

  private var locale = Locale(identifier: SpeechLocaleResolver.fallbackIdentifier)
  private var assetsPrepared = false
  /// When preparation last failed. Time-stamped rather than a flag: latching
  /// it forever meant one offline launch disabled speech for the whole
  /// lifetime of the process, with no way back short of a restart.
  private var lastPreparationFailure: Date?
  private var lastFailureWasOffline = false
  private var reservedLocale: Locale?

  private static let retryFailureAfter: TimeInterval = 60

  public init() {}

  public var isAvailable: Bool {
    get async {
      if assetsPrepared { return true }
      let installed = await Self.installedIdentifiers()
      let target = localeIdentifier
      return installed.contains { $0.caseInsensitiveCompare(target) == .orderedSame }
    }
  }

  /// Pick the locale from the Mac's language settings. Call before `prepare()`;
  /// safe to call again when the system language changes.
  public func resolveLocale(
    preferredLanguages: [String] = Locale.preferredLanguages,
    regionHint: String? = Locale.current.region?.identifier
  ) async {
    let supported = await Self.supportedIdentifiers()
    let picked = SpeechLocaleResolver.resolve(
      preferredLanguages: preferredLanguages, regionHint: regionHint, supported: supported)
    guard picked != localeIdentifier else { return }
    // Reservations are a bounded resource; a user who switches system
    // language a few times would otherwise exhaust the budget silently.
    await releaseReservation()
    localeIdentifier = picked
    locale = Locale(identifier: picked)
    assetsPrepared = false
    lastPreparationFailure = nil
  }

  /// Installs Apple's on-demand transcription assets once. The only network
  /// touch in transcription, through Apple's own asset channel; afterwards
  /// everything is offline.
  public func prepare() async {
    guard !assetsPrepared else { return }
    if let failure = lastPreparationFailure,
      Date().timeIntervalSince(failure) < Self.retryFailureAfter
    { return }
    do {
      let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
      if let request = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber])
      {
        try await request.downloadAndInstall()
      }
      _ = try? await AssetInventory.reserve(locale: locale)
      reservedLocale = locale
      assetsPrepared = true
      lastPreparationFailure = nil
    } catch {
      lastPreparationFailure = Date()
      lastFailureWasOffline = Self.looksOffline(error)
    }
  }

  public func assetState() async -> SpeechAssetState {
    if assetsPrepared { return .ready(localeIdentifier: localeIdentifier) }
    if lastPreparationFailure != nil {
      return .failed(localeIdentifier: localeIdentifier, offline: lastFailureWasOffline)
    }
    let installed = await Self.installedIdentifiers()
    return installed.contains(where: { $0.caseInsensitiveCompare(localeIdentifier) == .orderedSame })
      ? .ready(localeIdentifier: localeIdentifier)
      : .needsInstall(localeIdentifier: localeIdentifier)
  }

  public func transcribe(audio: URL, hints: [String]) async throws -> TranscriptionResult {
    await prepare()
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    let context = AnalysisContext()
    let terms = BiasTerms.sanitize(hints)
    if !terms.isEmpty { context.contextualStrings = [.general: terms] }

    let file = try AVAudioFile(forReading: audio)
    let durationSeconds =
      file.processingFormat.sampleRate > 0
      ? Double(file.length) / file.processingFormat.sampleRate : 0

    let analyzer = try await SpeechAnalyzer(
      inputAudioFile: file, modules: [transcriber], analysisContext: context,
      finishAfterFile: true)
    var pieces: [String] = []
    for try await result in transcriber.results {
      let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      pieces.append(text)
    }
    _ = analyzer
    let text = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw SpeechEngineError("nothing recognized")
    }
    return TranscriptionResult(text: text, durationSeconds: durationSeconds)
  }

  private func releaseReservation() async {
    guard let reservedLocale else { return }
    await AssetInventory.release(reservedLocale: reservedLocale)
    self.reservedLocale = nil
  }

  static func supportedIdentifiers() async -> [String] {
    await SpeechTranscriber.supportedLocales.map(\.identifier)
  }

  static func installedIdentifiers() async -> [String] {
    await SpeechTranscriber.installedLocales.map(\.identifier)
  }

  /// URLErrors are how a missing network surfaces through the asset channel.
  private static func looksOffline(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
      .cannotConnectToHost, .dataNotAllowed, .timedOut:
      return true
    default:
      return false
    }
  }
}
