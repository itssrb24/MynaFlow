import Foundation
import Testing

@testable import MynaFlowCore

@Suite("SecureFieldDetector")
struct SecureFieldDetectorTests {
  @Test(
    "Secure and password roles are detected, ordinary fields are not",
    arguments: [
      ("AXTextField", "AXSecureTextField", true),
      ("AXSecureTextField", "", true),
      ("AXTextField", "AXPasswordField", true),
      ("axtextfield", "axsecuretextfield", true),
      ("AXTextField", "", false),
      ("AXTextArea", "AXStandardTextArea", false),
      ("", "", false),
    ])
  func detection(role: String, subrole: String, expected: Bool) {
    #expect(SecureFieldDetector.isSecure(role: role, subrole: subrole) == expected)
  }

  @Test("Nil attributes are not secure")
  func nilAttributes() {
    #expect(SecureFieldDetector.isSecure(role: nil, subrole: nil) == false)
  }
}

@Suite("ClipboardCleanupPolicy")
struct ClipboardCleanupPolicyTests {
  @Test("Restores only when clipboard still holds our exact payload and change count")
  func restoreGuard() {
    #expect(
      ClipboardCleanupPolicy.shouldRestore(
        current: "dictated", expectedPayload: "dictated",
        currentChangeCount: 7, expectedChangeCount: 7))
    // User copied something newer — never clobber it.
    #expect(
      !ClipboardCleanupPolicy.shouldRestore(
        current: "user's own copy", expectedPayload: "dictated",
        currentChangeCount: 8, expectedChangeCount: 7))
    // Same text but a new change count means someone re-copied; leave it.
    #expect(
      !ClipboardCleanupPolicy.shouldRestore(
        current: "dictated", expectedPayload: "dictated",
        currentChangeCount: 8, expectedChangeCount: 7))
    #expect(
      !ClipboardCleanupPolicy.shouldRestore(
        current: nil, expectedPayload: "dictated",
        currentChangeCount: 7, expectedChangeCount: 7))
  }
}

@Suite("InsertionPlanner")
struct InsertionPlannerTests {
  @Test(
    "Decision table",
    arguments: [
      // (accessibility granted, has focused element, secure field, expected)
      (true, true, false, InsertionPlan.axInsert),
      // Secure field: hard abort — nothing touches the pasteboard.
      (true, true, true, .refuseSecureField),
      // No focused field: history + clipboard recovery.
      (true, false, false, .historyPlusClipboard),
      (true, false, true, .historyPlusClipboard),
      // Without accessibility we cannot inspect or insert at all.
      (false, true, false, .historyPlusClipboard),
      (false, false, false, .historyPlusClipboard),
    ])
  func decisions(
    accessibilityGranted: Bool, hasFocusedElement: Bool, isSecureField: Bool,
    expected: InsertionPlan
  ) {
    let plan = InsertionPlanner.plan(
      accessibilityGranted: accessibilityGranted,
      hasFocusedElement: hasFocusedElement,
      isSecureField: isSecureField)
    #expect(plan == expected)
  }

  @Test("Blind paste is opt-in, and never overrides a field we can actually see")
  func blindPaste() {
    // The Google Docs case: nothing focused that we can see, user opted in.
    #expect(
      InsertionPlanner.plan(
        accessibilityGranted: true, hasFocusedElement: false, isSecureField: false,
        allowBlindPaste: true) == .blindPaste)
    // Same situation without the opt-in stays fail-closed.
    #expect(
      InsertionPlanner.plan(
        accessibilityGranted: true, hasFocusedElement: false, isSecureField: false,
        allowBlindPaste: false) == .historyPlusClipboard)
    // A visible secure field still wins over the opt-in.
    #expect(
      InsertionPlanner.plan(
        accessibilityGranted: true, hasFocusedElement: true, isSecureField: true,
        allowBlindPaste: true) == .refuseSecureField)
    // No Accessibility means no synthesized keystrokes either.
    #expect(
      InsertionPlanner.plan(
        accessibilityGranted: false, hasFocusedElement: false, isSecureField: false,
        allowBlindPaste: true) == .historyPlusClipboard)
  }
}
