import AppKit
import MynaFlowCore

/// NSEvent global + local monitors dispatching hotkey edges. Observes only —
/// global monitors cannot swallow events, which is why default bindings avoid
/// character-emitting chords.
@MainActor
final class GlobalHotkeyMonitor {
  private var configuration: HotkeyConfiguration
  private let onHoldDown: () -> Void
  private let onHoldUp: () -> Void
  private let onToggle: () -> Void
  private let onCancel: () -> Void
  private let onChordAbort: () -> Void
  private let onStyle: (HotkeyAction) -> Void
  private var globalMonitors: [Any] = []
  private var localMonitor: Any?
  private var holdActive = false
  /// True when the current hold was started by a modifier-only shortcut —
  /// its release is detected on flagsChanged, not keyUp.
  private var holdViaModifiers = false

  init(
    configuration: HotkeyConfiguration,
    onHoldDown: @escaping () -> Void,
    onHoldUp: @escaping () -> Void,
    onToggle: @escaping () -> Void,
    onCancel: @escaping () -> Void,
    onChordAbort: @escaping () -> Void,
    onStyle: @escaping (HotkeyAction) -> Void = { _ in }
  ) {
    self.configuration = configuration
    self.onHoldDown = onHoldDown
    self.onHoldUp = onHoldUp
    self.onToggle = onToggle
    self.onCancel = onCancel
    self.onChordAbort = onChordAbort
    self.onStyle = onStyle
  }

  func update(configuration: HotkeyConfiguration) {
    self.configuration = configuration
    // Remapping while a hold is active must not strand the microphone open.
    if holdActive {
      holdActive = false
      holdViaModifiers = false
      onHoldUp()
    }
  }

  func install() {
    uninstall()
    if let monitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged],
      handler: { [weak self] event in
        // Global monitor handlers are delivered on the main thread, so run
        // synchronously (matching the local monitor) instead of hopping
        // through a Task — the async hop could reorder a key-down after its
        // key-up and strand the "recording" state.
        MainActor.assumeIsolated { self?.handle(event) }
      })
    {
      globalMonitors.append(monitor)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { [weak self] event in
      self?.handle(event)
      return event
    }
  }

  func uninstall() {
    globalMonitors.forEach(NSEvent.removeMonitor)
    globalMonitors.removeAll()
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    localMonitor = nil
  }

  private func handle(_ event: NSEvent) {
    let flags = HotkeyShortcut.normalized(
      event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)

    if event.type == .flagsChanged {
      handleFlagsChanged(current: flags)
      return
    }

    // Chord guard first: a character key arriving during a modifier-only
    // hold means the user was typing a regular shortcut (⌃C, ⌘S…), not
    // dictating — abort so bare-modifier push-to-talk doesn't hijack every
    // OS shortcut that shares its modifier. Must precede the cancel and
    // style branches, or a style chord during a ⌃-hold leaves the mic open.
    if event.type == .keyDown, !event.isARepeat, holdViaModifiers {
      holdActive = false
      holdViaModifiers = false
      onChordAbort()
      return
    }
    if event.type == .keyDown,
      configuration[.cancel]?.matches(keyCode: event.keyCode, modifiers: flags) == true
    {
      onCancel()
      return
    }
    // Single-press actions (styles, undo, re-insert) are live whenever the
    // app is running.
    if event.type == .keyDown, !event.isARepeat {
      for action in HotkeyAction.styleActions + [.undoLast, .reinsertLast, .openScratchpad]
      where configuration[action]?.matches(keyCode: event.keyCode, modifiers: flags) == true {
        onStyle(action)
        return
      }
    }
    if event.type == .keyDown, !event.isARepeat {
      if configuration[.dictationHold]?.matches(keyCode: event.keyCode, modifiers: flags) == true,
        !holdActive
      {
        holdActive = true
        onHoldDown()
      }
      if configuration[.dictationToggle]?.matches(keyCode: event.keyCode, modifiers: flags) == true {
        onToggle()
      }
    } else if event.type == .keyUp {
      if holdActive, !holdViaModifiers,
        event.keyCode == configuration[.dictationHold]?.keyCode
      {
        holdActive = false
        onHoldUp()
      }
    }
  }

  /// Modifier-only shortcuts: press edge = the held modifier set exactly
  /// equals the shortcut's set; release edge = any modifier of that set lifts.
  private func handleFlagsChanged(current flags: UInt) {
    // Release edge first, so ⌃ → ⌃⌥ transitions can't double-trigger.
    if holdViaModifiers, let hold = configuration[.dictationHold],
      !contains(flags, all: hold.modifiers)
    {
      holdActive = false
      holdViaModifiers = false
      onHoldUp()
    }

    if configuration[.cancel]?.matchesModifiers(flags) == true {
      onCancel()
      return
    }
    if configuration[.dictationHold]?.matchesModifiers(flags) == true, !holdActive {
      holdActive = true
      holdViaModifiers = true
      onHoldDown()
    }
    if configuration[.dictationToggle]?.matchesModifiers(flags) == true {
      onToggle()
    }
  }

  private func contains(_ flags: UInt, all required: UInt) -> Bool {
    flags & required == required
  }
}
