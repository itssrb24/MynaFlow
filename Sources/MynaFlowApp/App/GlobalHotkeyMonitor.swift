import AppKit
import MynaFlowCore

/// NSEvent global + local monitors dispatching hotkey edges. Observes only —
/// global monitors cannot swallow events, which is why default bindings avoid
/// character-emitting chords.
@MainActor
final class GlobalHotkeyMonitor {
  private var router: HotkeyRouter
  private let onHoldDown: () -> Void
  private let onHoldUp: () -> Void
  private let onToggle: () -> Void
  private let onCancel: () -> Void
  private let onChordAbort: () -> Void
  private let onStyle: (HotkeyAction) -> Void
  private var globalMonitors: [Any] = []
  private var localMonitor: Any?

  init(
    configuration: HotkeyConfiguration,
    onHoldDown: @escaping () -> Void,
    onHoldUp: @escaping () -> Void,
    onToggle: @escaping () -> Void,
    onCancel: @escaping () -> Void,
    onChordAbort: @escaping () -> Void,
    onStyle: @escaping (HotkeyAction) -> Void = { _ in }
  ) {
    router = HotkeyRouter(configuration: configuration)
    self.onHoldDown = onHoldDown
    self.onHoldUp = onHoldUp
    self.onToggle = onToggle
    self.onCancel = onCancel
    self.onChordAbort = onChordAbort
    self.onStyle = onStyle
  }

  func update(configuration: HotkeyConfiguration) {
    apply(router.updateConfiguration(configuration))
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
    let input: HotkeyInput
    switch event.type {
    case .flagsChanged:
      input = .flagsChanged(modifiers: flags)
    case .keyDown:
      input = .keyDown(keyCode: event.keyCode, modifiers: flags, isRepeat: event.isARepeat)
    case .keyUp:
      input = .keyUp(keyCode: event.keyCode)
    default:
      return
    }
    apply(router.route(input))
  }

  private func apply(_ effects: [HotkeyEffect]) {
    for effect in effects {
      switch effect {
      case .holdDown: onHoldDown()
      case .holdUp: onHoldUp()
      case .toggle: onToggle()
      case .cancel: onCancel()
      case .chordAbort: onChordAbort()
      case .action(let action): onStyle(action)
      }
    }
  }
}
