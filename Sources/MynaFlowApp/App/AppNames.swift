import AppKit

/// Human-readable app names for bundle identifiers shown in History,
/// Insights, and App Rules.
@MainActor
enum AppNames {
  /// `NSWorkspace.urlForApplication` hits Launch Services on every call; the
  /// views ask for the same handful of ids on every render, so answers are
  /// memoized for the life of the process.
  private static var cache: [String: String] = [:]

  /// "com.apple.TextEdit" → "TextEdit" when the app is on disk, else the id.
  static func display(_ bundleID: String) -> String {
    if let cached = cache[bundleID] { return cached }
    let name = resolve(bundleID)
    cache[bundleID] = name
    return name
  }

  private static func resolve(_ bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return FileManager.default.displayName(atPath: url.path)
        .replacingOccurrences(of: ".app", with: "")
    }
    return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
  }
}
