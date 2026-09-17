import Foundation

/// Serializes history for the user's own use. Pure: the caller chooses the
/// destination (a save panel) and writes the bytes owner-only.
public enum HistoryExporter {
  public enum Format: String, CaseIterable, Sendable {
    case json, markdown

    public var fileExtension: String {
      switch self {
      case .json: "json"
      case .markdown: "md"
      }
    }

    public var displayName: String {
      switch self {
      case .json: "JSON"
      case .markdown: "Markdown"
      }
    }
  }

  public static func export(_ records: [DictationRecord], as format: Format) throws -> Data {
    switch format {
    case .json: try json(records)
    case .markdown: Data(markdown(records).utf8)
    }
  }

  /// Stable field order and ISO-8601 timestamps so exports diff cleanly.
  static func json(_ records: [DictationRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(records)
  }

  static func markdown(_ records: [DictationRecord]) -> String {
    var lines = ["# Myna Flow history", ""]
    let stamp = ISO8601DateFormatter()
    for record in records {
      var meta = [stamp.string(from: record.timestamp), record.engineUsed]
      if let app = record.targetApp { meta.append(app) }
      if let style = record.styleApplied { meta.append("style: \(style)") }
      lines.append("## \(meta.joined(separator: " · "))")
      lines.append("")
      lines.append(record.finalText)
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }
}
