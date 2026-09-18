import Foundation

/// Per-app overrides keyed by bundle identifier. Every field is optional:
/// nil means "use the global setting", so a rule only ever narrows behavior
/// the user asked for in that one app.
public struct AppRule: Identifiable, Codable, Equatable, Sendable {
  public let bundleID: String
  public var cleanupEnabled: Bool?
  /// Whether the cleaner adds a terminal period. Off for chat and terminals.
  public var terminalPeriod: Bool?
  /// Rewrite every dictation in this style before inserting it.
  public var polishStyleID: UUID?
  /// Paste into this app even when its focused field is invisible to
  /// Accessibility. Needed by canvas editors such as Google Docs, and opt-in
  /// because an unseen field cannot be checked for being a password field.
  public var pasteWhenUnseen: Bool?

  public var id: String { bundleID }

  public init(
    bundleID: String, cleanupEnabled: Bool? = nil, terminalPeriod: Bool? = nil,
    polishStyleID: UUID? = nil, pasteWhenUnseen: Bool? = nil
  ) {
    self.bundleID = bundleID
    self.cleanupEnabled = cleanupEnabled
    self.terminalPeriod = terminalPeriod
    self.polishStyleID = polishStyleID
    self.pasteWhenUnseen = pasteWhenUnseen
  }

  /// A rule with nothing set is noise; callers delete instead of storing it.
  public var isEmpty: Bool {
    cleanupEnabled == nil && terminalPeriod == nil && polishStyleID == nil
      && pasteWhenUnseen == nil
  }
}
