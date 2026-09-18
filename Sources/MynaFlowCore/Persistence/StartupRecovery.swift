import Foundation

/// What to do when the history database will not open: move it aside with
/// a timestamp so nothing is lost, and let the app start on a fresh one.
public enum StartupRecovery {
  public static func moveAsideURL(for database: URL, at date: Date) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stem = database.deletingPathExtension().lastPathComponent
    let ext = database.pathExtension
    let name = "\(stem).corrupt-\(formatter.string(from: date)).\(ext)"
    return database.deletingLastPathComponent().appendingPathComponent(name)
  }

  /// SQLite's WAL and shared-memory files must travel with the main file, or
  /// a fresh database would inherit a stale journal.
  public static func sidecarURLs(for database: URL) -> [URL] {
    ["-wal", "-shm", "-journal"].map {
      URL(fileURLWithPath: database.path + $0)
    }
  }

  /// Moves the database and its sidecars aside; returns the new main path.
  @discardableResult
  public static func moveAside(database: URL, at date: Date = Date()) throws -> URL {
    let fileManager = FileManager.default
    let aside = moveAsideURL(for: database, at: date)
    if fileManager.fileExists(atPath: database.path) {
      try fileManager.moveItem(at: database, to: aside)
    }
    for sidecar in sidecarURLs(for: database) where fileManager.fileExists(atPath: sidecar.path) {
      let suffix = String(sidecar.lastPathComponent.dropFirst(database.lastPathComponent.count))
      try fileManager.moveItem(at: sidecar, to: URL(fileURLWithPath: aside.path + suffix))
    }
    return aside
  }
}
