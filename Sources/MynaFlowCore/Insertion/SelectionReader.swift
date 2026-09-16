import AppKit
import ApplicationServices
import Foundation

/// Reads the selected text of the frontmost app's focused element, for the
/// polish flow. Secure fields read as nil — their contents never enter a
/// prompt.
@MainActor
public enum SelectionReader {
  public static func selectedText() -> String? {
    guard let focused = focusedElement(for: NSWorkspace.shared.frontmostApplication) else {
      return nil
    }
    let role: String = copyAttribute(focused, kAXRoleAttribute) ?? ""
    let subrole: String = copyAttribute(focused, kAXSubroleAttribute) ?? ""
    guard !SecureFieldDetector.isSecure(role: role, subrole: subrole) else { return nil }
    return copyAttribute(focused, kAXSelectedTextAttribute)
  }
}
