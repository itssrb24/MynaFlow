import AppKit
import ApplicationServices
import Foundation

/// Reads the selected text of the frontmost app's focused element, for the
/// polish flow. Secure fields read as nil — their contents never enter a
/// prompt.
/// A handle on the field that just received dictated text, so its value
/// can be re-read while the user edits it. Secure fields never yield one.
@MainActor
public final class FocusedField {
  private let element: AXUIElement

  fileprivate init(element: AXUIElement) {
    self.element = element
  }

  public var value: String? {
    copyAttribute(element, kAXValueAttribute)
  }
}

@MainActor
public enum SelectionReader {
  public static func focusedField() -> FocusedField? {
    guard let focused = focusedElement(for: NSWorkspace.shared.frontmostApplication) else {
      return nil
    }
    let role: String = copyAttribute(focused, kAXRoleAttribute) ?? ""
    let subrole: String = copyAttribute(focused, kAXSubroleAttribute) ?? ""
    guard !SecureFieldDetector.isSecure(role: role, subrole: subrole) else { return nil }
    return FocusedField(element: focused)
  }

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
