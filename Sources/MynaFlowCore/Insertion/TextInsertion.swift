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
  /// `allowBlindPaste` permits pasting into an app whose focused element is
  /// invisible to Accessibility. Only ever true where the user asked for it.
  func insert(
    _ text: String, replacingSelection: Bool, pressEnter: Bool, allowBlindPaste: Bool
  ) async throws -> TextInsertionResult
  func undo() async throws
}

extension TextInsertionService {
  public func insert(_ text: String, replacingSelection: Bool, pressEnter: Bool) async throws
    -> TextInsertionResult
  {
    try await insert(
      text, replacingSelection: replacingSelection, pressEnter: pressEnter, allowBlindPaste: false)
  }
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
  /// Paste into an app whose focused element we cannot see, because the user
  /// asked for it — either by clicking Paste themselves, or by turning the
  /// per-app rule on. Some editors (Google Docs' canvas) expose no text
  /// element at all, so this is the only way text ever reaches them.
  case blindPaste
  /// No usable destination — write history and copy to the clipboard, and say
  /// so explicitly in the indicator.
  case historyPlusClipboard
  /// Focused element is a password field: abort with nothing on the pasteboard.
  case refuseSecureField
}

/// Whether a focused accessibility element can take typed text.
///
/// A paste into Finder's file list "succeeds" — nothing errors — but nothing
/// lands, and the value check that would notice has no text to compare. So
/// roles that plainly can't take text are recognised up front. Anything
/// unfamiliar (web and Electron editors report AXGroup or AXWebArea) is
/// allowed, so editors that work today keep working.
public enum TextTarget {
  static let nonTextRoles: Set<String> = [
    "AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid", "AXImage", "AXButton",
    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuBar",
    "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXScrollBar", "AXToolbar", "AXTabGroup",
    "AXDisclosureTriangle", "AXRow", "AXColumn", "AXCell", "AXSplitter", "AXProgressIndicator",
  ]

  /// `hasSelectedTextRange`: the element exposes a text caret, which beats
  /// whatever its role claims.
  public static func acceptsText(role: String, hasSelectedTextRange: Bool) -> Bool {
    hasSelectedTextRange || !nonTextRoles.contains(role)
  }
}

public enum InsertionPlanner {
  public static func plan(
    accessibilityGranted: Bool,
    hasFocusedElement: Bool,
    isSecureField: Bool,
    acceptsText: Bool = true,
    allowBlindPaste: Bool = false
  ) -> InsertionPlan {
    // Posting keystrokes needs the same grant reading the tree does.
    guard accessibilityGranted else { return .historyPlusClipboard }
    guard hasFocusedElement else {
      return allowBlindPaste ? .blindPaste : .historyPlusClipboard
    }
    // A field we *can* see and that is secure is refused however we got here.
    guard !isSecureField else { return .refuseSecureField }
    // Focus is on something that can't hold text (a file list, a button):
    // a paste would vanish, so keep the text and say where it went.
    guard acceptsText || allowBlindPaste else { return .historyPlusClipboard }
    return .axInsert
  }
}
