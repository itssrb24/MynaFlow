import Foundation

public enum InsightsPeriod: String, CaseIterable, Sendable {
  case day, week, month, all

  public var displayName: String {
    switch self {
    case .day: "Today"
    case .week: "7 days"
    case .month: "30 days"
    case .all: "All time"
    }
  }

  func since(now: Date, calendar: Calendar) -> Date? {
    switch self {
    case .day: calendar.startOfDay(for: now)
    case .week: calendar.date(byAdding: .day, value: -7, to: now)
    case .month: calendar.date(byAdding: .day, value: -30, to: now)
    case .all: nil
    }
  }
}

public struct AppUsage: Equatable, Sendable {
  public let bundleID: String
  public let dictations: Int
  public let words: Int
}

public struct EngineShare: Equatable, Sendable {
  public let engine: String
  public let count: Int
}

public struct StyleUsage: Equatable, Sendable {
  public let style: String
  public let count: Int
}

public struct DailyWords: Equatable, Sendable {
  public let day: Date
  public let words: Int
}

public struct Insights: Equatable, Sendable {
  public let totalWords: Int
  public let totalDictations: Int
  public let totalDictationSeconds: Double
  /// Actual speaking pace over the period.
  public let speakingWPM: Double
  /// Typing time the user would have spent minus time spent dictating.
  public let timeSavedSeconds: Double
  public let topApps: [AppUsage]
  public let engineSplit: [EngineShare]
  public let fallbackRate: Double
  public let styleUsage: [StyleUsage]
  public let averageProcessingMs: Int
  public let p95ProcessingMs: Int
  /// Last 14 days, oldest first, every day present.
  public let dailyWords: [DailyWords]
}

/// Pure over records so every number is testable with fixtures.
public enum InsightsAggregator {
  public static let trendDays = 14

  public static func aggregate(
    _ allRecords: [DictationRecord],
    typingWPM: Double,
    now: Date = Date(),
    calendar: Calendar = .current,
    period: InsightsPeriod = .all
  ) -> Insights {
    let records: [DictationRecord]
    if let since = period.since(now: now, calendar: calendar) {
      records = allRecords.filter { $0.timestamp >= since }
    } else {
      records = allRecords
    }

    let totalWords = records.reduce(0) { $0 + $1.wordCount }
    let totalSeconds = records.reduce(0.0) { $0 + $1.durationSeconds }
    let speakingWPM = totalSeconds > 0 ? Double(totalWords) / (totalSeconds / 60) : 0
    let typingSeconds = typingWPM > 0 ? Double(totalWords) / typingWPM * 60 : 0
    let timeSaved = max(0, typingSeconds - totalSeconds)

    var appWords: [String: (dictations: Int, words: Int)] = [:]
    var engineCounts: [String: Int] = [:]
    var styleCounts: [String: Int] = [:]
    var fallbacks = 0
    for record in records {
      if let app = record.targetApp {
        let current = appWords[app] ?? (0, 0)
        appWords[app] = (current.dictations + 1, current.words + record.wordCount)
      }
      engineCounts[record.engineUsed, default: 0] += 1
      if let style = record.styleApplied {
        styleCounts[style, default: 0] += 1
      }
      if record.fallbackOccurred { fallbacks += 1 }
    }

    let topApps =
      appWords.map { AppUsage(bundleID: $0.key, dictations: $0.value.dictations, words: $0.value.words) }
      .sorted { $0.words != $1.words ? $0.words > $1.words : $0.bundleID < $1.bundleID }
    let engineSplit =
      engineCounts.map { EngineShare(engine: $0.key, count: $0.value) }
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0.engine < $1.engine }
    let styleUsage =
      styleCounts.map { StyleUsage(style: $0.key, count: $0.value) }
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0.style < $1.style }

    let latencies = records.map(\.processingMs).sorted()
    let average = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count
    let p95: Int
    if latencies.isEmpty {
      p95 = 0
    } else {
      let rank = Int((Double(latencies.count) * 0.95).rounded(.up))
      p95 = latencies[max(0, min(latencies.count - 1, rank - 1))]
    }

    // Daily trend over the whole history (not the period) so the chart is
    // always the same shape.
    var byDay: [Date: Int] = [:]
    for record in allRecords {
      byDay[calendar.startOfDay(for: record.timestamp), default: 0] += record.wordCount
    }
    let today = calendar.startOfDay(for: now)
    let daily: [DailyWords] = (0..<trendDays).reversed().compactMap { offset in
      guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
      return DailyWords(day: day, words: byDay[day] ?? 0)
    }

    return Insights(
      totalWords: totalWords,
      totalDictations: records.count,
      totalDictationSeconds: totalSeconds,
      speakingWPM: speakingWPM,
      timeSavedSeconds: timeSaved,
      topApps: topApps,
      engineSplit: engineSplit,
      fallbackRate: records.isEmpty ? 0 : Double(fallbacks) / Double(records.count),
      styleUsage: styleUsage,
      averageProcessingMs: average,
      p95ProcessingMs: p95,
      dailyWords: daily)
  }
}
