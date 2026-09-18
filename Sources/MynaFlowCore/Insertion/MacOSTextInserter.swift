import AppKit
import ApplicationServices
import Foundation

/// AX-first text insertion with a captured-target model: the destination is
/// captured at dictation start, verified still focused before anything is
/// pasted, and cleared afterwards. Ported from Myna's MacOSBridges.swift.
@MainActor
public final class MacOSTextInserter: TextInsertionService {
  private var capturedElement: AXUIElement?
  private var capturedApplication: NSRunningApplication?
  private var capturedBundleIdentifier: String?
  private var clipboardCleanupTask: Task<Void, Never>?
  private var clipboardCleanupGeneration = UUID()
  private var hasPendingClipboardFallback = false
  private var fallbackOriginalClipboard: String?
  private static let clipboardFallbackTimeout: Duration = .seconds(30)
  public private(set) var lastInsertionDiagnostics = "No insertion attempted"

  public init() {}

  /// Processes whose Chromium accessibility tree this session has woken.
  private var wokenChromiumPids: Set<pid_t> = []

  /// Chromium keeps its accessibility tree dormant until an assistive client
  /// announces itself, so Electron apps answer focus queries with silence.
  /// AXManualAccessibility is Electron's documented wake-up switch; native
  /// apps refuse the attribute and lose nothing. The tree builds
  /// asynchronously, so the first dictation in a freshly woken app may still
  /// take the clipboard route; every later one resolves the field.
  private func wakeChromiumAccessibility(of application: NSRunningApplication) {
    let pid = application.processIdentifier
    guard !wokenChromiumPids.contains(pid) else { return }
    wokenChromiumPids.insert(pid)
    let element = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  }

  /// Snapshot the frontmost app + focused element at dictation start.
  /// Returns the target's bundle identifier for the history record.
  @discardableResult
  public func captureTarget() -> String? {
    capturedApplication = NSWorkspace.shared.frontmostApplication
    if let capturedApplication { wakeChromiumAccessibility(of: capturedApplication) }
    capturedElement = focusedElement(for: capturedApplication)

    if let capturedElement {
      var processIdentifier: pid_t = 0
      if AXUIElementGetPid(capturedElement, &processIdentifier) == .success {
        capturedApplication = NSRunningApplication(processIdentifier: processIdentifier)
      }
    }

    capturedBundleIdentifier = capturedApplication?.bundleIdentifier
    return capturedBundleIdentifier
  }

  public var hasCapturedElement: Bool { capturedElement != nil }

  public func clearTarget() {
    capturedElement = nil
    capturedApplication = nil
  }

  public func insert(
    _ text: String,
    replacingSelection: Bool,
    pressEnter: Bool,
    allowBlindPaste: Bool = false
  ) async throws -> TextInsertionResult {
    let applicationReady = await activateCapturedApplication()
    let focusedTarget = focusedElement(for: capturedApplication)
    if capturedElement != nil, !capturedTargetIsStillFocused(focusedTarget) {
      return safeFallbackForChangedTarget(text, current: focusedTarget)
    }
    var resolvedTarget = focusedTarget ?? currentFocusedElement()
    if resolvedTarget == nil, let application = capturedApplication ?? NSWorkspace.shared.frontmostApplication {
      // Chromium and Electron only build an accessibility tree once asked,
      // and can still be building it when we first look.
      wokenChromiumPids.remove(application.processIdentifier)
      wakeChromiumAccessibility(of: application)
      try? await Task.sleep(for: .milliseconds(120))
      resolvedTarget = focusedElement(for: application)
    }
    let role: String = resolvedTarget.flatMap { copyAttribute($0, kAXRoleAttribute) } ?? ""
    let subrole: String = resolvedTarget.flatMap { copyAttribute($0, kAXSubroleAttribute) } ?? ""
    // Without Accessibility every query above fails anyway; asking the OS
    // directly makes the plan explicit instead of relying on that side effect.
    let plan = InsertionPlanner.plan(
      accessibilityGranted: AXIsProcessTrusted(),
      hasFocusedElement: resolvedTarget != nil,
      isSecureField: SecureFieldDetector.isSecure(role: role, subrole: subrole),
      allowBlindPaste: allowBlindPaste)

    switch plan {
    case .blindPaste:
      // No element to verify, so this route exists only where the user asked
      // for it. Activate the target, paste, and take the text back off the
      // pasteboard once it has landed.
      let previousClipboard = clipboardBeforeOwnedWrite()
      guard copyToClipboard(text) else {
        lastInsertionDiagnostics = diagnostic(
          route: "blind-paste", role: "unavailable", focus: "unresolved",
          clipboard: "failed", value: "unavailable")
        return .noFocusedField
      }
      let ownedChangeCount = NSPasteboard.general.changeCount
      postPasteShortcut()
      try? await Task.sleep(for: .milliseconds(350))
      lastInsertionDiagnostics = diagnostic(
        route: "blind-paste", role: "unavailable", focus: "unresolved",
        clipboard: "ready", value: "unverified")
      if pressEnter { postKey(keyCode: 36) }
      restoreClipboard(
        to: previousClipboard, onlyIfCurrentEquals: text,
        expectedChangeCount: ownedChangeCount)
      return .pastedFromClipboard
    case .historyPlusClipboard:
      // Fail closed: with no resolvable focused element we cannot rule out a
      // password field, so never synthesize a paste into the unknown. The
      // text goes to the clipboard and history; the indicator says so.
      let previousClipboard = clipboardBeforeOwnedWrite()
      let clipboardReady = copyToClipboard(text)
      _ = applicationReady
      lastInsertionDiagnostics = diagnostic(
        route: "clipboard-only", role: "unavailable", focus: "unresolved",
        clipboard: clipboardReady ? "ready" : "failed", value: "unavailable")
      if clipboardReady { scheduleClipboardCleanup(payload: text, previous: previousClipboard) }
      return .noFocusedField
    case .refuseSecureField:
      // Never place dictated text on the general pasteboard for a secure or
      // password field — any other app can read it. Abort insertion entirely.
      lastInsertionDiagnostics =
        "Secure field blocked; role=\(role); subrole=\(subrole); clipboard=skipped"
      return .blockedSecureField
    case .axInsert:
      break
    }
    // `.axInsert` is only ever planned with a resolved element.
    guard let target = resolvedTarget else { return .noFocusedField }

    let selected: String? = copyAttribute(target, kAXSelectedTextAttribute)
    let valueBefore: String? = copyAttribute(target, kAXValueAttribute)

    // Chromium and Electron editors can report success for kAXSelectedText
    // while silently discarding the value. A real paste into the captured
    // field is reliable across native, browser, and Electron text controls,
    // so it is the primary insertion path.
    if applicationReady || focusCapturedTarget(target) {
      let previousClipboard = clipboardBeforeOwnedWrite()
      let clipboardReady = copyToClipboard(text)
      let ownedChangeCount = NSPasteboard.general.changeCount
      guard clipboardReady else {
        lastInsertionDiagnostics = diagnostic(
          route: "paste", role: role, focus: "ready", clipboard: "failed", value: "unchanged")
        return .copiedToClipboard
      }
      // Clipboard preparation and app activation both yield long enough for
      // the user to click elsewhere. Never post Command-V unless the exact
      // element captured at dictation start still owns focus.
      if capturedElement != nil,
        !capturedTargetIsStillFocused(focusedElement(for: capturedApplication))
      {
        return safeFallbackForChangedTarget(
          text, current: focusedElement(for: capturedApplication),
          previousClipboard: previousClipboard, restorePreviousClipboard: true)
      }
      postPasteShortcut()
      try? await Task.sleep(for: .milliseconds(350))
      let valueAfter: String? = copyAttribute(target, kAXValueAttribute)
      let valueState: String
      if let valueBefore, let valueAfter {
        valueState = valueBefore == valueAfter ? "unchanged" : "changed"
      } else {
        valueState = "unavailable"
      }
      lastInsertionDiagnostics = diagnostic(
        route: "paste", role: role, focus: "ready", clipboard: "ready", value: valueState)
      if pressEnter { postKey(keyCode: 36) }
      // Programmatic paste is done; do not leave dictated text on the
      // pasteboard. After the 350 ms paste settle, restore only if the user
      // has not copied something else in the meantime.
      restoreClipboard(
        to: previousClipboard, onlyIfCurrentEquals: text,
        expectedChangeCount: ownedChangeCount)
      return .pastedFromClipboard
    }

    let result = AXUIElementSetAttributeValue(
      target, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    if result == .success {
      lastInsertionDiagnostics = diagnostic(
        route: "accessibility", role: role, focus: "failed", clipboard: "unused",
        value: "unverified")
      if pressEnter { postKey(keyCode: 36) }
      return replacingSelection || !(selected ?? "").isEmpty ? .replacedSelection : .inserted
    }

    let fallbackPreviousClipboard = clipboardBeforeOwnedWrite()
    let clipboardReady = copyToClipboard(text)
    lastInsertionDiagnostics = diagnostic(
      route: "clipboard-only", role: role, focus: "failed",
      clipboard: clipboardReady ? "ready" : "failed", value: "unchanged")
    if clipboardReady {
      scheduleClipboardCleanup(payload: text, previous: fallbackPreviousClipboard)
    }
    return clipboardReady ? .copiedToClipboard : .noFocusedField
  }

  public func undo() async throws {
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 6, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  @discardableResult
  private func copyToClipboard(_ text: String) -> Bool {
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(text, forType: .string)
  }

  private func clipboardBeforeOwnedWrite() -> String? {
    hasPendingClipboardFallback
      ? fallbackOriginalClipboard
      : NSPasteboard.general.string(forType: .string)
  }

  /// Explicit copy fallback remains available to the user, but its dictated
  /// text must not persist indefinitely. After 30 seconds, restore the prior
  /// string only if no newer clipboard content replaced our exact payload.
  private func scheduleClipboardCleanup(payload: String, previous: String?) {
    if !hasPendingClipboardFallback {
      fallbackOriginalClipboard = previous
      hasPendingClipboardFallback = true
    }
    clipboardCleanupTask?.cancel()
    let generation = UUID()
    clipboardCleanupGeneration = generation
    let expectedChangeCount = NSPasteboard.general.changeCount
    clipboardCleanupTask = Task { [weak self] in
      try? await Task.sleep(for: Self.clipboardFallbackTimeout)
      guard !Task.isCancelled else { return }
      guard let self, self.clipboardCleanupGeneration == generation else { return }
      let original = self.fallbackOriginalClipboard
      let shouldRestore = ClipboardCleanupPolicy.shouldRestore(
        current: NSPasteboard.general.string(forType: .string),
        expectedPayload: payload,
        currentChangeCount: NSPasteboard.general.changeCount,
        expectedChangeCount: expectedChangeCount)
      self.clearPendingClipboardFallback()
      guard shouldRestore else { return }
      NSPasteboard.general.clearContents()
      if let original { NSPasteboard.general.setString(original, forType: .string) }
    }
  }

  /// Restores the pasteboard's prior string contents after a programmatic
  /// paste so dictated text does not linger on `NSPasteboard.general` where
  /// any app can read it.
  private func restoreClipboard(
    to previous: String?, onlyIfCurrentEquals expected: String,
    expectedChangeCount: Int
  ) {
    let shouldRestore = ClipboardCleanupPolicy.shouldRestore(
      current: NSPasteboard.general.string(forType: .string),
      expectedPayload: expected,
      currentChangeCount: NSPasteboard.general.changeCount,
      expectedChangeCount: expectedChangeCount)
    clearPendingClipboardFallback()
    guard shouldRestore else { return }
    NSPasteboard.general.clearContents()
    if let previous {
      NSPasteboard.general.setString(previous, forType: .string)
    }
  }

  private func clearPendingClipboardFallback() {
    clipboardCleanupTask?.cancel()
    clipboardCleanupTask = nil
    clipboardCleanupGeneration = UUID()
    hasPendingClipboardFallback = false
    fallbackOriginalClipboard = nil
  }

  private func diagnostic(
    route: String, role: String, focus: String, clipboard: String, value: String
  ) -> String {
    let bundleIdentifier = capturedBundleIdentifier ?? "unknown-app"
    let safeRole = role.isEmpty ? "unknown-role" : role
    return
      "target=\(bundleIdentifier); role=\(safeRole); route=\(route); focus=\(focus); clipboard=\(clipboard); value=\(value)"
  }

  private func currentFocusedElement() -> AXUIElement? {
    focusedElement(for: NSWorkspace.shared.frontmostApplication)
  }

  private func capturedTargetIsStillFocused(_ current: AXUIElement?) -> Bool {
    guard let capturedElement, let current else { return false }
    return CFEqual(capturedElement, current)
  }

  private func safeFallbackForChangedTarget(
    _ text: String, current: AXUIElement?, previousClipboard: String? = nil,
    restorePreviousClipboard: Bool = false
  ) -> TextInsertionResult {
    let role: String = current.flatMap { copyAttribute($0, kAXRoleAttribute) } ?? ""
    let subrole: String = current.flatMap { copyAttribute($0, kAXSubroleAttribute) } ?? ""
    // Unresolvable new focus is indeterminate: treat it as secure rather than
    // placing the text where a password field might be listening.
    if current == nil || SecureFieldDetector.isSecure(role: role, subrole: subrole) {
      if restorePreviousClipboard {
        restoreClipboard(
          to: previousClipboard, onlyIfCurrentEquals: text,
          expectedChangeCount: NSPasteboard.general.changeCount)
      }
      lastInsertionDiagnostics =
        "Secure field blocked after target changed; role=\(role); subrole=\(subrole); clipboard=skipped"
      return .blockedSecureField
    }
    let fallbackPreviousClipboard =
      restorePreviousClipboard
      ? previousClipboard
      : clipboardBeforeOwnedWrite()
    let clipboardReady = copyToClipboard(text)
    lastInsertionDiagnostics = diagnostic(
      route: "target-changed", role: role, focus: "changed",
      clipboard: clipboardReady ? "ready" : "failed", value: "unchanged")
    if clipboardReady {
      // The caller may have copied the payload already, but it remains the
      // user's explicit fallback; keep it available for the bounded window.
      scheduleClipboardCleanup(payload: text, previous: fallbackPreviousClipboard)
    }
    return clipboardReady ? .copiedToClipboard : .noFocusedField
  }

  private func focusCapturedTarget(_ target: AXUIElement) -> Bool {
    let focusResult = AXUIElementSetAttributeValue(
      target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    return focusResult == .success || capturedApplication?.isActive == true
  }

  private func activateCapturedApplication() async -> Bool {
    guard let application = capturedApplication, !application.isTerminated else { return false }
    let activated = application.activate()
    for _ in 0..<12 where !application.isActive {
      try? await Task.sleep(for: .milliseconds(50))
    }
    try? await Task.sleep(for: .milliseconds(200))
    return activated || application.isActive
  }

  private func postPasteShortcut() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let commandKeyCode: CGKeyCode = 55
    let pasteKeyCode: CGKeyCode = 9

    let commandDown = CGEvent(
      keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true)
    commandDown?.flags = .maskCommand
    commandDown?.post(tap: .cghidEventTap)

    let pasteDown = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true)
    pasteDown?.flags = .maskCommand
    pasteDown?.post(tap: .cghidEventTap)

    let pasteUp = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false)
    pasteUp?.flags = .maskCommand
    pasteUp?.post(tap: .cghidEventTap)

    let commandUp = CGEvent(
      keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
    commandUp?.flags = []
    commandUp?.post(tap: .cghidEventTap)
  }

  private func postKey(keyCode: CGKeyCode) {
    postShortcut(keyCode: keyCode, flags: [])
  }

  private func postShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }
}

// MARK: - Focused-element resolution (shared with SelectionReader)

@MainActor
func focusedElement(for application: NSRunningApplication?) -> AXUIElement? {
  if let application {
    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    if let focused: AXUIElement = copyAttribute(
      applicationElement, kAXFocusedUIElementAttribute)
    {
      return deepestFocusedElement(startingAt: focused)
    }
  }

  let system = AXUIElementCreateSystemWide()
  guard let focused: AXUIElement = copyAttribute(system, kAXFocusedUIElementAttribute) else {
    return nil
  }
  return deepestFocusedElement(startingAt: focused)
}

@MainActor
private func deepestFocusedElement(startingAt root: AXUIElement) -> AXUIElement {
  var current = root
  for _ in 0..<8 {
    guard let next: AXUIElement = copyAttribute(current, kAXFocusedUIElementAttribute),
      !CFEqual(current, next)
    else { break }
    current = next
  }

  let role: String = copyAttribute(current, kAXRoleAttribute) ?? ""
  guard role == (kAXWindowRole as String) || role == (kAXGroupRole as String) else {
    return current
  }

  var remainingElements = 500
  var fallbackEditable: AXUIElement?
  return editableDescendant(
    of: current,
    depth: 0,
    remainingElements: &remainingElements,
    fallbackEditable: &fallbackEditable
  ) ?? fallbackEditable ?? current
}

@MainActor
private func editableDescendant(
  of element: AXUIElement,
  depth: Int,
  remainingElements: inout Int,
  fallbackEditable: inout AXUIElement?
) -> AXUIElement? {
  guard depth < 14, remainingElements > 0 else { return nil }
  remainingElements -= 1

  let role: String = copyAttribute(element, kAXRoleAttribute) ?? ""
  let focused: Bool = copyAttribute(element, kAXFocusedAttribute) ?? false
  let enabled: Bool = copyAttribute(element, kAXEnabledAttribute) ?? true
  let isEditable =
    role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
    || role == (kAXComboBoxRole as String)

  if focused, enabled, isEditable {
    return element
  }

  if enabled, isEditable {
    // Electron applications do not always expose the focused state on their
    // contenteditable control. Keep the best editable descendant as a safe
    // fallback, preferring a text area over generic fields.
    if fallbackEditable == nil || role == (kAXTextAreaRole as String) {
      fallbackEditable = element
    }
  }

  let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) ?? []
  for child in children {
    if let match = editableDescendant(
      of: child,
      depth: depth + 1,
      remainingElements: &remainingElements,
      fallbackEditable: &fallbackEditable
    ) {
      return match
    }
  }
  return nil
}

@MainActor
func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
  var value: CFTypeRef?
  let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
  guard result == .success else { return nil }
  return value as? T
}
