import AppKit
import MynaFlowCore
import os

/// Watches the calendar and which apps hold the mic, and asks — through a
/// small top-of-screen prompt — whether to take meeting notes. It never
/// records on its own: Start always comes from the user. The one automatic
/// action is the agreed one: a "call ended" prompt left unanswered stops
/// the notes when its countdown runs out.
@MainActor
@Observable
final class MeetingDetectionController {
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "meeting")
  private static let tick: Duration = .seconds(2)
  private static let promptSeconds = 60
  private static let callsKey = "meeting_detect_calls"
  private static let calendarKey = "meeting_detect_calendar"
  private static let excludedCalendarsKey = "meeting_calendars_excluded"

  /// Ask when a meeting app or browser joins a call. Needs no permission.
  private(set) var callsEnabled = true
  /// Ask at calendar meeting start. Needs Calendar access.
  private(set) var calendarEnabled = false

  let calendar = CalendarSource()

  @ObservationIgnored private var detector = MeetingDetector()
  @ObservationIgnored private var store: FlowStore?
  @ObservationIgnored private weak var recorder: MeetingRecorder?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var countdown: Task<Void, Never>?
  @ObservationIgnored private var shown: DetectionPrompt?
  /// The recording a shown prompt was raised during (see `recordingCount`).
  @ObservationIgnored private var shownForRecording = 0
  @ObservationIgnored private lazy var panel = MeetingPromptPanelController()

  func configure(store: FlowStore, recorder: MeetingRecorder) async {
    self.store = store
    self.recorder = recorder
    recorder.currentCalendarTitle = { [weak self] in
      guard let self, self.calendarEnabled else { return nil }
      return CalendarMeeting.current(in: self.calendar.meetings, at: Date())?.title
    }
    callsEnabled = (try? await store.setting(forKey: Self.callsKey)) != "0"
    calendar.selection = CalendarSelection(
      encoded: try? await store.setting(forKey: Self.excludedCalendarsKey))
    calendarEnabled =
      (try? await store.setting(forKey: Self.calendarKey)) == "1" && calendar.isAuthorized
    if calendarEnabled { calendar.start() }
    updateLoop()
  }

  func setCallsEnabled(_ enabled: Bool) {
    callsEnabled = enabled
    save(enabled, Self.callsKey)
    updateLoop()
  }

  /// Turning calendar prompts on asks for Calendar access first.
  func setCalendarEnabled(_ enabled: Bool) async {
    if enabled, !calendar.isAuthorized, !(await calendar.requestAccess()) {
      calendarEnabled = false
      return
    }
    calendarEnabled = enabled
    if enabled { calendar.start() } else { calendar.stop() }
    save(enabled, Self.calendarKey)
    updateLoop()
  }

  /// Include or exclude one calendar from meeting prompts.
  func setCalendar(_ id: String, watched: Bool) {
    calendar.selection = calendar.selection.setting(id, watched: watched)
    let encoded = calendar.selection.encoded
    Task { [store] in
      do {
        try await store?.setSetting(encoded, forKey: Self.excludedCalendarsKey)
      } catch {
        Self.log.error("save calendar selection failed: \(error.localizedDescription)")
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
    withdraw()
    calendar.stop()
  }

  // MARK: - Loop

  private func updateLoop() {
    guard callsEnabled || calendarEnabled else {
      loop?.cancel()
      loop = nil
      withdraw()
      return
    }
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.evaluate()
        try? await Task.sleep(for: Self.tick)
      }
    }
  }

  private func evaluate() {
    let phase = recorder?.phase ?? .idle
    let activity =
      callsEnabled ? MicActivityMonitor.current() : MicActivityMonitor.Activity(mic: [], playing: [])
    let input = DetectionInput(
      now: Date(),
      events: calendarEnabled ? calendar.meetings : [],
      micHolders: activity.mic,
      callAudioHolders: activity.playing,
      isRecording: phase != .idle)
    // A start prompt is moot once notes are running (started from the menu),
    // and a stop prompt is moot once they've stopped.
    if let shown, isStale(shown, phase: phase) {
      detector.resolve(shown, outcome: .accepted)
      dismissPanel()
    }
    let prompt = detector.evaluate(input)
    // The call came back (a network drop, a rejoin): the stop countdown
    // must not end a meeting that is still going.
    if case .callEnded? = shown, detector.recordedCallIsLive { withdraw() }
    guard let prompt else { return }
    withdraw()
    present(prompt)
  }

  private func isStale(_ prompt: DetectionPrompt, phase: MeetingRecorder.Phase) -> Bool {
    switch prompt {
    case .calendarStart, .callJoined: phase != .idle
    case .callEnded: phase != .recording || recorder?.recordingCount != shownForRecording
    }
  }

  // MARK: - Prompt

  private func present(_ prompt: DetectionPrompt) {
    Self.log.info("meeting prompt: \(String(describing: prompt.kind), privacy: .public)")
    shown = prompt
    shownForRecording = recorder?.recordingCount ?? 0
    let model = panel.model
    model.content = Self.content(for: prompt)
    model.secondsLeft = Self.promptSeconds
    model.totalSeconds = Self.promptSeconds
    model.onPrimary = { [weak self] in self?.answer(prompt, primary: true) }
    model.onSecondary = { [weak self] in self?.answer(prompt, primary: false) }
    panel.show()
    countdown?.cancel()
    countdown = Task { [weak self] in
      while !Task.isCancelled, let self, self.panel.model.secondsLeft > 0 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self.panel.model.secondsLeft -= 1
      }
      guard !Task.isCancelled else { return }
      self?.timedOut(prompt)
    }
  }

  private func answer(_ prompt: DetectionPrompt, primary: Bool) {
    let stale = shown.map { isStale($0, phase: recorder?.phase ?? .idle) } ?? true
    detector.resolve(prompt, outcome: primary ? .accepted : .dismissed)
    dismissPanel()
    guard primary, !stale, let recorder else { return }
    Task {
      switch prompt {
      case .calendarStart(let meeting): await recorder.start(title: meeting.title)
      case .callJoined(_, let meeting): await recorder.start(title: meeting?.title)
      case .callEnded: await recorder.stop()
      }
    }
  }

  private func timedOut(_ prompt: DetectionPrompt) {
    guard shown == prompt else { return }
    if case .callEnded = prompt {
      // Agreed behaviour: an unanswered "call ended" stops the notes.
      answer(prompt, primary: true)
    } else {
      detector.resolve(prompt, outcome: .expired)
      dismissPanel()
    }
  }

  /// Takes down whatever prompt is showing, telling the detector it went
  /// unanswered so a later signal for the same meeting can still ask.
  private func withdraw() {
    if let shown { detector.resolve(shown, outcome: .expired) }
    dismissPanel()
  }

  private func dismissPanel() {
    countdown?.cancel()
    countdown = nil
    shown = nil
    panel.hide()
  }

  private static func content(for prompt: DetectionPrompt) -> MeetingPromptContent {
    switch prompt {
    case .calendarStart(let meeting):
      MeetingPromptContent(
        title: meeting.title,
        subtitle: "Starts at \(meeting.start.formatted(date: .omitted, time: .shortened))"
          + (meeting.link != nil ? " · video call" : ""),
        detail: "Take meeting notes? Audio stays on this Mac and is deleted as it's transcribed.",
        primary: "Start Notes", secondary: "Not Now", tone: .start, timeoutLabel: "Closes in")
    case .callJoined(let app, let meeting):
      MeetingPromptContent(
        title: meeting?.title ?? "\(app.name) is using the mic",
        subtitle: "\(app.name) · on a call",
        detail: "Looks like you joined a call. Take meeting notes?",
        primary: "Start Notes", secondary: "Not Now", tone: .start, timeoutLabel: "Closes in")
    case .callEnded(let app):
      MeetingPromptContent(
        title: "Call ended",
        subtitle: "\(app.name) let go of the mic",
        detail: "Stop and summarize the meeting notes?",
        primary: "Stop & Summarize", secondary: "Keep Recording", tone: .stop,
        timeoutLabel: "Stops in")
    }
  }

  private func save(_ enabled: Bool, _ key: String) {
    Task { [store] in
      do {
        try await store?.setSetting(enabled ? "1" : "0", forKey: key)
      } catch {
        Self.log.error("save \(key, privacy: .public) failed: \(error.localizedDescription)")
      }
    }
  }
}

private extension DetectionPrompt {
  /// For logs: which kind of prompt, never meeting titles.
  var kind: String {
    switch self {
    case .calendarStart: "calendar start"
    case .callJoined(let app, _): "call joined (\(app.name))"
    case .callEnded(let app): "call ended (\(app.name))"
    }
  }
}
