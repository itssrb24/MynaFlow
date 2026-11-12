import AppKit
import MynaFlowCore
import UniformTypeIdentifiers
import os

/// App-side owner of meeting notes: two captures (mic → "You", system output
/// → "Others") feeding one `MeetingSession`, a persistent top-of-screen
/// indicator for the whole recording, and the saved-meetings list the
/// Meetings page shows. Start and stop are only ever explicit.
@MainActor
@Observable
final class MeetingRecorder {
  nonisolated private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "meeting")

  enum Phase: Equatable {
    case idle
    /// Between the click and both captures running; blocks a second start.
    case starting
    case recording
    case finishing
  }

  private(set) var phase: Phase = .idle
  private(set) var meetings: [MeetingRecord] = []
  /// One-line status for the page: an error, or why a summary is missing.
  private(set) var notice: String?
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

  @ObservationIgnored private var store: FlowStore?
  @ObservationIgnored private var scratch: URL?
  @ObservationIgnored private var makeTranscriber: () -> (any TranscriptionProviding)? = { nil }
  @ObservationIgnored private var currentModel: () -> (any LocalLanguageModel)? = { nil }

  func configure(
    store: FlowStore,
    scratch: URL,
    transcriber: @escaping () -> (any TranscriptionProviding)?,
    model: @escaping () -> (any LocalLanguageModel)?
  ) async {
    self.store = store
    self.scratch = scratch
    makeTranscriber = transcriber
    currentModel = model
    await refresh()
  }

  func setInputDevice(_ uid: String?) {
    mic.preferredDeviceUID = uid
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

  /// `title` names the calendar meeting the notes are for, when known.
  func start(title: String? = nil) async {
    guard phase == .idle, let store, let scratch, let transcriber = makeTranscriber() else {
      if store == nil { notice = "Meeting notes are unavailable until Myna Flow finishes starting." }
      return
    }
    notice = nil
    phase = .starting
    let session = MeetingSession(
      transcriber: transcriber,
      summarizer: MeetingSummarizer(model: currentModel()),
      store: store,
      scratchDirectory: scratch)
    do {
      try await session.start(title: title)
      self.session = session
      let others = try system.start()
      mic.duckOtherAudio = false
      let you = try mic.start { [weak self] level in self?.indicator.submitAudioLevel(level) }
      mic.onConfigurationChange = { [weak self] in
        self?.notice = "The microphone changed mid-meeting, so recording stopped."
        self?.toggle()
      }
      pumps = [pump(you, into: session, channel: .you), pump(others, into: session, channel: .others)]
    } catch {
      Self.log.error("meeting start failed: \(error.localizedDescription)")
      await teardownCaptures()
      await session.cancel()
      self.session = nil
      notice = error.localizedDescription
      phase = .idle
      return
    }
    phase = .recording
    recordingCount += 1
    showIndicator()
  }

  func stop() async {
    guard phase == .recording, let session else { return }
    phase = .finishing
    timer?.cancel()
    indicator.display = .processing(engine: "meeting notes")
    // Let the pumps hand over every captured frame before the session closes.
    await teardownCaptures()
    let result = await session.stop()
    self.session = nil
    phase = .idle
    switch result {
    case .saved(let record):
      notice = record.summaryNote
      let words = record.segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
      indicator.display = .success(words: words, note: "Meeting notes saved")
      await refresh()
    case .failed(let message, let transcript):
      // Never lose the words: the transcript goes to the clipboard.
      let copied =
        !transcript.isEmpty
        && PasteboardHygiene.write(MeetingTranscript.render(transcript), restoreAfter: .seconds(600))
      notice = copied ? "\(message) The transcript is on the clipboard." : message
      indicator.display = .error("Meeting not saved")
    case .cancelled, .notRecording:
      indicator.display = .hidden
    }
    hideIndicatorSoon()
  }

  /// Abandons a recording; every audio chunk is deleted, nothing is saved.
  func cancel() async {
    guard phase != .idle, let session else { return }
    timer?.cancel()
    await session.cancel()
    await teardownCaptures()
    self.session = nil
    phase = .idle
    indicator.display = .hidden
    panel?.hide()
  }

  func refresh() async {
    meetings = (try? await store?.meetings(limit: 200)) ?? []
  }

  func delete(_ meeting: MeetingRecord) async {
    do {
      try await store?.deleteMeeting(id: meeting.id)
    } catch {
      notice = "Could not delete the meeting: \(error.localizedDescription)"
    }
    await refresh()
  }

  func copyMarkdown(_ meeting: MeetingRecord) {
    _ = PasteboardHygiene.write(MeetingExporter.markdown(meeting))
  }

  func export(_ meeting: MeetingRecord) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Data(MeetingExporter.markdown(meeting).utf8).write(to: url, options: .atomic)
    } catch {
      notice = "Export failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Private

  private func pump(_ frames: AsyncStream<AudioFrame>, into session: MeetingSession, channel: MeetingChannel)
    -> Task<Void, Never>
  {
    Task.detached(priority: .userInitiated) {
      for await frame in frames {
        await session.append(frame, channel: channel)
      }
    }
  }

  /// Stops both captures (finishing their streams) and waits for the pumps
  /// to drain into the session.
  private func teardownCaptures() async {
    mic.onConfigurationChange = {}
    mic.stop()
    system.stop()
    for pump in pumps { await pump.value }
    pumps = []
  }

  private func showIndicator() {
    if panel == nil {
      let controller = IndicatorPanelController(model: indicator)
      // Top of the screen, clear of the dictation pill's default spot.
      controller.placement = .topCenter
      panel = controller
    }
    indicator.resetAudioLevel()
    indicator.elapsedSeconds = 0
    indicator.display = .recording(mode: .toggle)
    indicator.onStopRequested = { [weak self] in self?.toggle() }
    panel?.show()
    timer?.cancel()
    timer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self?.indicator.elapsedSeconds += 1
      }
    }
  }

  private func hideIndicatorSoon() {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      guard let self, self.phase == .idle else { return }
      self.indicator.display = .hidden
      self.panel?.hide()
    }
  }
}
