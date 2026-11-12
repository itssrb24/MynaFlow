import AppKit
import EventKit
import Foundation
import MynaFlowCore
import os

/// Upcoming meetings from the Mac's own calendar store (EventKit). Accounts
/// the user added in System Settings — Google, Outlook, iCloud — sync there
/// through macOS; Myna Flow only reads the local store and opens no
/// connection of its own.
///
/// Fetches on connect, whenever the store changes, and every five minutes;
/// the detector's two-second tick only ever reads `meetings`.
/// One calendar the user can include or exclude, for the picker.
struct CalendarOption: Identifiable, Equatable {
  let id: String
  let title: String
  /// The account it belongs to ("iCloud", "Google", a work Exchange).
  let account: String
  let color: CGColor?
}

@MainActor
@Observable
final class CalendarSource {
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "calendar")
  private static let lookBehind: TimeInterval = 10 * 60
  private static let lookAhead: TimeInterval = 12 * 60 * 60
  private static let refreshInterval: Duration = .seconds(300)

  private(set) var meetings: [CalendarMeeting] = []
  /// Every event calendar on this Mac, grouped by account in the picker.
  private(set) var calendars: [CalendarOption] = []
  /// Which calendars to watch; changing it re-reads events at once.
  var selection = CalendarSelection() {
    didSet { if selection != oldValue { refresh() } }
  }
  private(set) var authorization = EKEventStore.authorizationStatus(for: .event)

  @ObservationIgnored private let store = EKEventStore()
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private nonisolated(unsafe) var changeObserver: (any NSObjectProtocol)?

  var isAuthorized: Bool { authorization == .fullAccess }

  deinit {
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
  }

  /// Shows the system prompt the first time; afterwards returns the answer.
  func requestAccess() async -> Bool {
    do {
      _ = try await store.requestFullAccessToEvents()
    } catch {
      Self.log.error("calendar access request failed: \(error.localizedDescription)")
    }
    authorization = EKEventStore.authorizationStatus(for: .event)
    if isAuthorized { start() }
    return isAuthorized
  }

  /// Begins keeping `meetings` current. No-op without access.
  func start() {
    authorization = EKEventStore.authorizationStatus(for: .event)
    guard isAuthorized, refreshTask == nil else { return }
    if changeObserver == nil {
      changeObserver = NotificationCenter.default.addObserver(
        forName: .EKEventStoreChanged, object: store, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
    }
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.refresh()
        try? await Task.sleep(for: Self.refreshInterval)
      }
    }
  }

  /// Privacy & Security → Calendars, for when access was denied.
  func openSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
      NSWorkspace.shared.open(url)
    }
  }

  func stop() {
    refreshTask?.cancel()
    refreshTask = nil
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    changeObserver = nil
    meetings = []
  }

  func refresh() {
    authorization = EKEventStore.authorizationStatus(for: .event)
    guard isAuthorized, refreshTask != nil else {
      meetings = []
      return
    }
    let all = store.calendars(for: .event)
    calendars = all.map {
      CalendarOption(
        id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Other",
        color: $0.cgColor)
    }
    .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    let watched = all.filter { selection.includes($0.calendarIdentifier) }
    // EventKit reads `calendars: []` as "no filter", so nothing watched must
    // be handled here rather than passed through.
    guard !watched.isEmpty else {
      meetings = []
      return
    }
    let now = Date()
    let predicate = store.predicateForEvents(
      withStart: now.addingTimeInterval(-Self.lookBehind),
      end: now.addingTimeInterval(Self.lookAhead), calendars: watched)
    meetings = store.events(matching: predicate)
      .compactMap(Self.meeting(from:))
      .sorted { $0.start < $1.start }
  }

  /// Timed events the user hasn't declined or seen cancelled, that look
  /// like meetings: a video link, or someone else invited. "Lunch" and
  /// subscribed calendars (holidays, sports) never prompt.
  private static func meeting(from event: EKEvent) -> CalendarMeeting? {
    let attendees = event.attendees ?? []
    guard !event.isAllDay, event.status != .canceled,
      attendees.first(where: \.isCurrentUser)?.participantStatus != .declined,
      let start = event.startDate, let end = event.endDate
    else { return nil }
    let link = ConferenceLink.find(in: [event.url?.absoluteString, event.location, event.notes])
    guard link != nil || attendees.contains(where: { !$0.isCurrentUser }) else { return nil }
    // Occurrences of a repeating event share an identifier; the start time
    // tells them apart so each occurrence prompts on its own day. The id
    // must be stable across refreshes or the same event would re-prompt.
    let id = "\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))"
    let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return CalendarMeeting(
      id: id, title: title.isEmpty ? "Untitled meeting" : title, start: start, end: end,
      link: link)
  }
}
