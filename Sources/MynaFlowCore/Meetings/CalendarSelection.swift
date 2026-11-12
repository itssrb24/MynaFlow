import Foundation

/// Which calendars meeting detection watches. Stored as the calendars the
/// user turned *off*, so a calendar added later (a new work account) is
/// watched by default and an empty selection means "all".
public struct CalendarSelection: Sendable, Equatable {
  public let excluded: Set<String>

  public init(excluded: Set<String> = []) {
    self.excluded = excluded
  }

  /// Reads a saved value; missing or unreadable means every calendar.
  public init(encoded: String?) {
    let ids = encoded.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    self.init(excluded: Set(ids ?? []))
  }

  /// JSON, since calendar identifiers are opaque and may contain anything.
  public var encoded: String {
    let data = (try? JSONEncoder().encode(excluded.sorted())) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  public func includes(_ calendarID: String) -> Bool {
    !excluded.contains(calendarID)
  }

  public func setting(_ calendarID: String, watched: Bool) -> CalendarSelection {
    CalendarSelection(
      excluded: watched ? excluded.subtracting([calendarID]) : excluded.union([calendarID]))
  }
}
