import Foundation

/// Browser-history style deletion ranges.
public enum DeletionRange: String, CaseIterable, Sendable {
  case lastHour
  case today
  case pastWeek
  case pastMonth
  case allTime

  public var displayName: String {
    switch self {
    case .lastHour: "Last hour"
    case .today: "Today"
    case .pastWeek: "Past week"
    case .pastMonth: "Past month"
    case .allTime: "All time"
    }
  }

  /// Rows with timestamp >= cutoff are deleted.
  public func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date {
    switch self {
    case .lastHour: now.addingTimeInterval(-3_600)
    case .today: calendar.startOfDay(for: now)
    case .pastWeek: calendar.date(byAdding: .day, value: -7, to: now) ?? now
    case .pastMonth: calendar.date(byAdding: .month, value: -1, to: now) ?? now
    case .allTime: .distantPast
    }
  }
}

/// Filters for the History view. All fields optional and ANDed together.
public struct HistoryQuery: Equatable, Sendable {
  public var text: String?
  public var targetApp: String?
  public var engine: String?
  public var since: Date?
  public var until: Date?

  public init(
    text: String? = nil, targetApp: String? = nil, engine: String? = nil,
    since: Date? = nil, until: Date? = nil
  ) {
    self.text = text
    self.targetApp = targetApp
    self.engine = engine
    self.since = since
    self.until = until
  }

  public var isEmpty: Bool {
    (text?.isEmpty ?? true) && targetApp == nil && engine == nil && since == nil && until == nil
  }
}
