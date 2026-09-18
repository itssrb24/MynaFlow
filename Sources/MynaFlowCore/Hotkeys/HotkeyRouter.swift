import AppKit
import Foundation

/// A raw key event, reduced to what routing actually depends on.
public enum HotkeyInput: Equatable, Sendable {
  case keyDown(keyCode: UInt16, modifiers: UInt, isRepeat: Bool)
  case keyUp(keyCode: UInt16)
  case flagsChanged(modifiers: UInt)
}

/// What the app should do about an event, in the order it should happen.
public enum HotkeyEffect: Equatable, Sendable {
  case holdDown
  case holdUp
  case toggle
  case cancel
  /// A character chord arrived during a bare-modifier hold: the user was
  /// reaching for a shortcut, not dictating.
  case chordAbort
  case action(HotkeyAction)
}

/// Pure routing for the global key monitor. Extracted from the monitor so the
/// interactions between bare-modifier holds, chords and single-press actions
/// are testable without synthesizing NSEvents.
public struct HotkeyRouter {
  private var configuration: HotkeyConfiguration
  private var holdActive = false
  /// True when the live hold began on a modifier-only shortcut, whose release
  /// arrives on flagsChanged rather than keyUp.
  private var holdViaModifiers = false

  /// Single-press actions, in match order.
  static let pressActions: [HotkeyAction] =
    HotkeyAction.styleActions + [.undoLast, .reinsertLast, .openScratchpad]

  public init(configuration: HotkeyConfiguration) {
    self.configuration = configuration
  }

  public var isHolding: Bool { holdActive }

  /// Remapping mid-hold must not strand the microphone open.
  public mutating func updateConfiguration(_ configuration: HotkeyConfiguration) -> [HotkeyEffect] {
    self.configuration = configuration
    guard holdActive else { return [] }
    holdActive = false
    holdViaModifiers = false
    return [.holdUp]
  }

  public mutating func route(_ input: HotkeyInput) -> [HotkeyEffect] {
    switch input {
    case .keyDown(let keyCode, let modifiers, let isRepeat):
      return routeKeyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
    case .keyUp(let keyCode):
      guard holdActive, !holdViaModifiers, keyCode == configuration[.dictationHold]?.keyCode
      else { return [] }
      holdActive = false
      return [.holdUp]
    case .flagsChanged(let modifiers):
      return routeFlagsChanged(modifiers)
    }
  }

  private mutating func routeKeyDown(keyCode: UInt16, modifiers: UInt, isRepeat: Bool)
    -> [HotkeyEffect]
  {
    guard !isRepeat else { return [] }
    var effects: [HotkeyEffect] = []

    // A character key during a bare-modifier hold ends that hold. It must not
    // also swallow the chord: ⌃⌥1 on a ⌃ hold is a style press, not a cancel.
    if holdViaModifiers {
      holdActive = false
      holdViaModifiers = false
      effects.append(.chordAbort)
    }

    if configuration[.cancel]?.matches(keyCode: keyCode, modifiers: modifiers) == true {
      effects.append(.cancel)
      return effects
    }
    for action in Self.pressActions
    where configuration[action]?.matches(keyCode: keyCode, modifiers: modifiers) == true {
      effects.append(.action(action))
      return effects
    }
    if configuration[.dictationHold]?.matches(keyCode: keyCode, modifiers: modifiers) == true,
      !holdActive
    {
      holdActive = true
      effects.append(.holdDown)
    }
    if configuration[.dictationToggle]?.matches(keyCode: keyCode, modifiers: modifiers) == true {
      effects.append(.toggle)
    }
    return effects
  }

  /// Modifier-only shortcuts: the press edge is an exact set match, the
  /// release edge is any modifier of that set lifting.
  private mutating func routeFlagsChanged(_ flags: UInt) -> [HotkeyEffect] {
    var effects: [HotkeyEffect] = []
    // Release first, so a ⌃ → ⌃⌥ transition cannot double-trigger.
    if holdViaModifiers, let hold = configuration[.dictationHold],
      flags & hold.modifiers != hold.modifiers
    {
      holdActive = false
      holdViaModifiers = false
      effects.append(.holdUp)
    }
    if configuration[.cancel]?.matchesModifiers(flags) == true {
      effects.append(.cancel)
      return effects
    }
    if configuration[.dictationHold]?.matchesModifiers(flags) == true, !holdActive {
      holdActive = true
      holdViaModifiers = true
      effects.append(.holdDown)
    }
    if configuration[.dictationToggle]?.matchesModifiers(flags) == true {
      effects.append(.toggle)
    }
    return effects
  }
}
