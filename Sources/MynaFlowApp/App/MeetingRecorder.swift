import AppKit
import MynaFlowCore
import UniformTypeIdentifiers
import os

/// A status line for the Meetings page: what happened, how serious it is,
/// and optionally a file to reveal (a recovered transcript).
struct MeetingNotice: Equatable {
  enum Tone: Int, Comparable {
    case info, warning, error
    static func < (lhs: Tone, rhs: Tone) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  let text: String
  let tone: Tone
  var revealURL: URL?

  /// Two notices about the same meeting read as one, at the graver tone.
  func adding(_ other: MeetingNotice) -> MeetingNotice {
    MeetingNotice(
      text: text + " " + other.text, tone: max(tone, other.tone),
      revealURL: other.revealURL ?? revealURL)
  }
}

/// App-side owner of meeting notes: two captures (mic → "You", system output
/// → "Others") feeding one `MeetingSession`, a persistent top-of-screen
/// indicator for the whole recording, and the saved-meetings list the
/// Meetings page shows. Start and stop are only ever explicit.
@MainActor
@Observable
final class MeetingRecorder {
  nonisolated private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "meeting")
  /// When to check that other people's audio is arriving at all.
  private static let silenceCheckSeconds = 60
  private static let restartDebounce: Duration = .milliseconds(600)

  enum Phase: Equatable {
    case idle
    /// Between the click and both captures running; blocks a second start.
    case starting
    case recording
    case finishing
  }

  private(set) var phase: Phase = .idle
  private(set) var meetings: [MeetingRecord] = []
  private(set) var notice: MeetingNotice?
  /// Seconds recorded so far, for the Meetings page status line.
  private(set) var elapsedSeconds = 0
  var isRecording: Bool { phase == .recording }
  /// Bumped at each recording start, so an answer meant for one recording
  /// (a "call ended" countdown) can never stop the next one.
  private(set) var recordingCount = 0

  @ObservationIgnored let indicator = IndicatorModel()
  @ObservationIgnored private var panel: IndicatorPanelController?
  @ObservationIgnored private let mic = MicrophoneCapture()
  @ObservationIgnored private let system = SystemAudioCapture()
  @ObservationIgnored private var session: MeetingSession?
  @ObservationIgnored private var pumps: [Task<Void, Never>] = []
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var restart: Task<Void, Never>?

  @ObservationIgnored private var store: FlowStore?
  @ObservationIgnored private var scratch: URL?
  @ObservationIgnored private var recoveryDirectory: URL?
  @ObservationIgnored private var makeTranscriber: () -> (any TranscriptionProviding)? = { nil }
  @ObservationIgnored private var currentModel: () -> (any LocalLanguageModel)? = { nil }
  /// The calendar meeting happening now, for notes started by hand. Set by
  /// the detection controller; nil while calendar prompts are off.
  @ObservationIgnored var currentCalendarTitle: () -> String? = { nil }

  func configure(
    store: FlowStore,
    scratch: URL,
    recoveryDirectory: URL,
    transcriber: @escaping () -> (any TranscriptionProviding)?,
    model: @escaping () -> (any LocalLanguageModel)?
  ) async {
    self.store = store
    self.scratch = scratch
    self.recoveryDirectory = recoveryDirectory
    makeTranscriber = transcriber
    currentModel = model
    await refresh()
  }

  func setInputDevice(_ uid: String?) {
    mic.preferredDeviceUID = uid
  }

  func dismissNotice() {
    notice = nil
  }

  func toggle() {
    Task {
      switch phase {
      case .idle: await start()
      case .recording: await stop()
      case .starting, .finishing: break
      }
    }
  }

  // MARK: - Start

  /// `title` names the calendar meeting the notes are for, when known.
  func start(title: String? = nil) async {
    guard phase == .idle else { return }
    notice = nil
    guard let store, let scratch else {
      return fail("Meeting notes are unavailable until Myna Flow finishes starting.")
    }
    guard let transcriber = makeTranscriber() else {
      return fail("No speech engine is available, so meeting notes can't start.")
    }
    phase = .starting
    let session = MeetingSession(
      transcriber: transcriber,
      summarizer: MeetingSummarizer(model: currentModel()),
      store: store,
      scratchDirectory: scratch)
    // Registered before the first await, so a quit or Discard during
    // `.starting` can find and cancel it.
    self.session = session
    do {
      try await session.start(title: title ?? currentCalendarTitle())
      guard phase == .starting else {
        // Cancelled while the session was opening; close what it opened.
        await session.cancel()
        return
      }
      try startCaptures(into: session)
    } catch {
      Self.log.error("meeting start failed: \(error.localizedDescription)")
      await teardownCaptures()
      await session.cancel()
      self.session = nil
      phase = .idle
      return fail(error.localizedDescription)
    }
    phase = .recording
    recordingCount += 1
    showIndicator()
  }

  /// Both captures plus their pumps. Re-run after an audio route change.
  private func startCaptures(into session: MeetingSession) throws {
    let others = try system.start()
    // No voice processing: it silences the mic for every other app, so the
    // call would stop hearing the user. Speaker echo it would have removed is
    // dropped from the transcript by MeetingEcho instead.
    mic.useVoiceProcessing = false
    let you = try mic.start { [weak self] level in self?.indicator.submitAudioLevel(level) }
    // A device change (headphones, AirPods) or a sleep/wake reconfigures the
    // audio route under both captures. Rebuild them rather than stop.
    mic.onConfigurationChange = { [weak self] in self?.scheduleRestart() }
    system.onOutputDeviceChange = { [weak self] in self?.scheduleRestart() }
    pumps.append(pump(you, into: session, channel: .you))
    pumps.append(pump(others, into: session, channel: .others))
  }

  /// Device changes arrive in bursts; one restart covers the burst.
  private func scheduleRestart() {
    restart?.cancel()
    restart = Task { [weak self] in
      try? await Task.sleep(for: Self.restartDebounce)
      guard !Task.isCancelled else { return }
      await self?.restartCaptures()
    }
  }

  private func restartCaptures() async {
    guard phase == .recording, let session else { return }
    Self.log.info("audio route changed; restarting meeting capture")
    await teardownCaptures()
    do {
      try startCaptures(into: session)
    } catch {
      Self.log.error("meeting capture restart failed: \(error.localizedDescription)")
      post(
        "Recording stopped: the audio devices changed and capture couldn't resume "
          + "(\(error.localizedDescription)). What was said so far is saved.",
        .warning)
      await stop()
    }
  }

  // MARK: - Stop

  func stop() async {
    guard phase == .recording, let session else { return }
    phase = .finishing
    timer?.cancel()
    restart?.cancel()
    indicator.display = .processing(engine: "Summarizing meeting notes")
    // Let the pumps hand over every captured frame before the session closes.
    await teardownCaptures()
    let result = await session.stop()
    self.session = nil
    phase = .idle
    switch result {
    case .saved(let record):
      if let note = record.summaryNote { post(note, .info) }
      indicator.display = .success(words: 0, note: "Meeting notes saved")
      await refresh()
    case .failed(let message, let transcript):
      recover(transcript, as: unsavedRecord(of: transcript), message: message)
      indicator.display = .error("Meeting not saved")
    case .cancelled, .notRecording:
      indicator.display = .hidden
    }
    hideIndicatorSoon()
  }

  /// The app is quitting (or the Mac is restarting): keep what was said.
  /// Finishes the audio already captured and saves the transcript without
  /// a summary. If that takes longer than `limit`, the audio is discarded so
  /// quitting is never held up.
  func finishForQuit(limit: Duration = .seconds(8)) async {
    switch phase {
    case .idle:
      return
    case .starting:
      await cancel()
      return
    case .finishing:
      // A stop is already saving; give it the same allowance.
      _ = await Self.first(of: Task { await self.waitUntilIdle() }, within: limit)
      return
    case .recording:
      break
    }
    guard let session else { return }
    phase = .finishing
    timer?.cancel()
    restart?.cancel()
    await teardownCaptures()
    let save = Task {
      await session.stop(summarize: false, cutShortNote: Self.quitNote)
    }
    if await Self.first(of: save, within: limit) == nil {
      Self.log.error("meeting save on quit timed out; audio discarded")
      await session.cancel()
    }
    self.session = nil
    phase = .idle
  }

  static let quitNote =
    "Saved when Myna Flow quit, before the meeting could be summarized."

  /// Abandons a recording; every audio chunk is deleted, nothing is saved.
  func cancel() async {
    guard phase != .idle, let session else { return }
    phase = .idle
    timer?.cancel()
    restart?.cancel()
    await session.cancel()
    await teardownCaptures()
    self.session = nil
    indicator.display = .hidden
    panel?.hide()
  }

  // MARK: - Saved meetings

  func refresh() async {
    meetings = (try? await store?.meetings(limit: 200)) ?? []
  }

  func delete(_ meeting: MeetingRecord) async {
    do {
      try await store?.deleteMeeting(id: meeting.id)
    } catch {
      post("Could not delete the meeting: \(error.localizedDescription)", .error)
    }
    await refresh()
  }

  func copyMarkdown(_ meeting: MeetingRecord) {
    _ = PasteboardHygiene.write(MeetingExporter.markdown(meeting))
  }

  func export(_ meeting: MeetingRecord) {
    // A menu-bar app's save panel opens behind other windows unless the app
    // comes forward first.
    NSApp.activate()
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = Self.fileName(for: meeting)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Data(MeetingExporter.markdown(meeting).utf8).write(to: url, options: .atomic)
    } catch {
      post("Export failed: \(error.localizedDescription)", .error)
    }
  }

  func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  // MARK: - Failures

  /// A start that can't happen says so on the page and on the indicator, so
  /// a Start from the menu bar or a prompt never fails silently.
  private func fail(_ message: String) {
    post(message, .error)
    ensurePanel()
    indicator.display = .error(message)
    panel?.show()
    hideIndicatorSoon(after: .seconds(5))
  }

  private func post(_ text: String, _ tone: MeetingNotice.Tone, reveal: URL? = nil) {
    let new = MeetingNotice(text: text, tone: tone, revealURL: reveal)
    notice = notice.map { $0.adding(new) } ?? new
  }

  /// A save that failed never loses the words: the transcript is written to
  /// Recovered Meetings (kept across launches, unlike Scratch) and copied.
  private func recover(_ transcript: [MeetingSegment], as record: MeetingRecord, message: String) {
    guard !transcript.isEmpty else { return post(message, .error) }
    let markdown = MeetingExporter.markdown(record)
    _ = PasteboardHygiene.write(markdown, restoreAfter: .seconds(600))
    guard let directory = recoveryDirectory else {
      return post("\(message) The transcript is on the clipboard.", .error)
    }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let url = directory.appendingPathComponent(Self.fileName(for: record))
      try Data(markdown.utf8).write(to: url, options: .atomic)
      post("\(message) The transcript was saved to \(url.lastPathComponent).", .error, reveal: url)
    } catch {
      post("\(message) The transcript is on the clipboard.", .error)
    }
  }

  private func unsavedRecord(of transcript: [MeetingSegment]) -> MeetingRecord {
    MeetingRecord(
      startedAt: Date().addingTimeInterval(-Double(elapsedSeconds)),
      durationSeconds: Double(elapsedSeconds), segments: transcript, summary: nil,
      summaryNote: "Recovered: this meeting could not be saved to Myna Flow.")
  }

  private static func fileName(for meeting: MeetingRecord) -> String {
    meeting.title
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: ".") + ".md"
  }

  /// Audio stopped being written (a full disk): stop now and keep what was
  /// transcribed, rather than record an hour into nothing.
  private func handleWriteFailure() {
    guard phase == .recording else { return }
    post(
      "Meeting audio couldn't be written to disk (is it full?), so recording stopped. "
        + "What was transcribed is saved.",
      .error)
    Task { await stop() }
  }

  /// Callbacks arrive but carry only silence: most often System Audio
  /// Recording is off for Myna Flow (macOS then sends silence, not an error).
  private func checkOthersAudio() {
    guard phase == .recording, let health = system.health else { return }
    guard health.callbacks == 0 || health.peak == 0 else { return }
    post(
      "No sound from other apps yet. If others are talking, allow Myna Flow in "
        + "System Settings → Privacy & Security → Screen & System Audio Recording.",
      .warning)
  }

  // MARK: - Private

  private func pump(_ frames: AsyncStream<AudioFrame>, into session: MeetingSession, channel: MeetingChannel)
    -> Task<Void, Never>
  {
    Task.detached(priority: .userInitiated) { [weak self] in
      var reported = false
      for await frame in frames {
        let written = await session.append(frame, channel: channel)
        if !written, !reported {
          reported = true
          await self?.handleWriteFailure()
        }
      }
    }
  }

  /// Stops both captures (finishing their streams) and waits for the pumps
  /// to drain into the session.
  private func teardownCaptures() async {
    mic.onConfigurationChange = {}
    system.onOutputDeviceChange = {}
    mic.stop()
    system.stop()
    for pump in pumps { await pump.value }
    pumps = []
  }

  private func ensurePanel() {
    guard panel == nil else { return }
    let controller = IndicatorPanelController(model: indicator)
    // Top of the screen, clear of the dictation pill's default spot.
    controller.placement = .topCenter
    panel = controller
  }

  private func showIndicator() {
    ensurePanel()
    indicator.resetAudioLevel()
    indicator.elapsedSeconds = 0
    indicator.recordingLabel = "Meeting notes"
    indicator.display = .recording(mode: .toggle)
    indicator.onStopRequested = { [weak self] in self?.toggle() }
    panel?.show()
    elapsedSeconds = 0
    timer?.cancel()
    timer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        self.elapsedSeconds += 1
        self.indicator.elapsedSeconds = self.elapsedSeconds
        if self.elapsedSeconds == Self.silenceCheckSeconds { self.checkOthersAudio() }
      }
    }
  }

  private func hideIndicatorSoon(after delay: Duration = .seconds(2.5)) {
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, self.phase == .idle else { return }
      self.indicator.display = .hidden
      self.panel?.hide()
    }
  }

  private func waitUntilIdle() async {
    while phase != .idle, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  /// The task's value, or nil if `limit` passes first. Unlike a task group,
  /// this returns at the deadline even when the task can't be cancelled.
  private static func first<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T? {
    let race = FirstResult<T>()
    return await withCheckedContinuation { continuation in
      Task { await race.resolve(continuation, with: await task.value) }
      Task {
        try? await Task.sleep(for: limit)
        await race.resolve(continuation, with: nil)
      }
    }
  }
}

/// Resumes a continuation once, with whichever result arrives first.
private actor FirstResult<T: Sendable> {
  private var done = false

  func resolve(_ continuation: CheckedContinuation<T?, Never>, with value: T?) {
    guard !done else { return }
    done = true
    continuation.resume(returning: value)
  }
}
