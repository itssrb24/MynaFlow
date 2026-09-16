import Foundation

public enum TextInsertionResult: Equatable, Sendable {
  case inserted
  case replacedSelection
  case pastedFromClipboard
  case copiedToClipboard
  case noFocusedField
  /// The focused destination is a secure/password field. Nothing was inserted
  /// and, critically, nothing was placed on the pasteboard.
  case blockedSecureField
}

public protocol TextInsertionService: Sendable {
  func insert(_ text: String, replacingSelection: Bool, pressEnter: Bool) async throws
    -> TextInsertionResult
  func undo() async throws
}

public enum SecureFieldDetector {
  public static func isSecure(role: String?, subrole: String?) -> Bool {
    let haystacks = [role, subrole].compactMap { $0?.lowercased() }
    return haystacks.contains { $0.contains("secure") || $0.contains("password") }
  }
}

/// Guards cleanup after a paste: newer user clipboard content is never erased.
public enum ClipboardCleanupPolicy {
  public static func shouldRestore(
    current: String?, expectedPayload: String,
    currentChangeCount: Int, expectedChangeCount: Int
  ) -> Bool {
    current == expectedPayload && currentChangeCount == expectedChangeCount
  }
}

/// What the controller should do with finished text, decided up front from
/// observable state. Pure so the "no text loss" decision table is testable
/// without AppKit.
public enum InsertionPlan: Equatable, Sendable {
  /// Try AX insertion (with the inserter's own paste fallback inside).
  case axInsert
  /// No usable destination — write history and copy to the clipboard, and say
  /// so explicitly in the indicator.
  case historyPlusClipboard
  /// Focused element is a password field: abort with nothing on the pasteboard.
  case refuseSecureField
}

public enum InsertionPlanner {
  public static func plan(
    accessibilityGranted: Bool,
    hasFocusedElement: Bool,
    isSecureField: Bool
  ) -> InsertionPlan {
    guard accessibilityGranted else { return .historyPlusClipboard }
    guard hasFocusedElement else { return .historyPlusClipboard }
    guard !isSecureField else { return .refuseSecureField }
    return .axInsert
  }
}
