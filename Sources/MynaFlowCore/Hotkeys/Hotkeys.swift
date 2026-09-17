import AppKit
import Foundation

public enum HotkeyAction: String, CaseIterable, Codable, Sendable {
  case dictationHold
  case dictationToggle
  case cancel
  /// Polish the selection with the style bound to this slot (1–5).
  case style1, style2, style3, style4, style5

  public var displayName: String {
    switch self {
    case .dictationHold: "Hold to talk"
    case .dictationToggle: "Toggle dictation"
    case .cancel: "Cancel"
    case .style1: "Style slot 1"
    case .style2: "Style slot 2"
    case .style3: "Style slot 3"
    case .style4: "Style slot 4"
    case .style5: "Style slot 5"
    }
  }

  public static let styleActions: [HotkeyAction] = [.style1, .style2, .style3, .style4, .style5]

  /// The action driving a style table hotkey_slot (1–5).
  public static func forSlot(_ slot: Int) -> HotkeyAction? {
    styleActions.first { $0.styleSlot == slot }
  }

  /// The style table's hotkey_slot this action drives, if any.
  public var styleSlot: Int? {
    switch self {
    case .style1: 1
    case .style2: 2
    case .style3: 3
    case .style4: 4
    case .style5: 5
    default: nil
    }
  }
}

public struct HotkeyShortcut: Codable, Equatable, Sendable {
  /// Sentinel keyCode marking a modifier-only shortcut (hold ⌃, ⌃⌥, …).
  /// Chosen outside the valid HID keycode range so it can never collide with
  /// a real key.
  public static let modifierOnlyKeyCode: UInt16 = 0xFFFF

  public let keyCode: UInt16
  public let modifiers: UInt
  public let keyLabel: String

  public init(keyCode: UInt16, modifiers: UInt, keyLabel: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.keyLabel = keyLabel
  }

  /// A shortcut triggered by holding modifier keys alone — no character key.
  public static func modifierOnly(_ modifiers: UInt) -> HotkeyShortcut {
    HotkeyShortcut(
      keyCode: modifierOnlyKeyCode,
      modifiers: normalized(modifiers),
      keyLabel: "")
  }

  public var isModifierOnly: Bool { keyCode == Self.modifierOnlyKeyCode }

  public func matches(keyCode: UInt16, modifiers: UInt) -> Bool {
    !isModifierOnly && self.keyCode == keyCode && self.modifiers == Self.normalized(modifiers)
  }

  /// Exact-set match for modifier-only shortcuts: ⌃ matches ⌃ (capsLock etc.
  /// normalized away) but NOT ⌃⌥ — supersets must not trigger.
  public func matchesModifiers(_ modifiers: UInt) -> Bool {
    isModifierOnly && self.modifiers == Self.normalized(modifiers)
  }

  public var displayName: String {
    isModifierOnly ? modifierGlyphs + " (hold)" : modifierGlyphs + keyLabel
  }

  /// Compact glyphs for keycap chips ("⌃⌥1"), no "(hold)" suffix.
  public var keycapLabel: String {
    isModifierOnly ? modifierGlyphs : modifierGlyphs + keyLabel
  }

  private var modifierGlyphs: String {
    let flags = NSEvent.ModifierFlags(rawValue: modifiers)
    var result = ""
    if flags.contains(.control) { result += "⌃" }
    if flags.contains(.option) { result += "⌥" }
    if flags.contains(.shift) { result += "⇧" }
    if flags.contains(.command) { result += "⌘" }
    return result
  }

  public static func normalized(_ rawValue: UInt) -> UInt {
    NSEvent.ModifierFlags(rawValue: rawValue)
      .intersection([.command, .option, .control, .shift, .function])
      .rawValue
  }
}

/// Bindings for every action; nil means unbound (legal for style slots 4–5,
/// and for toggle if the user clears it). Persisted as MynaFlow.hotkeys.v1.
public struct HotkeyConfiguration: Codable, Equatable, Sendable {
  private var bindings: [String: HotkeyShortcut]

  public init(bindings: [HotkeyAction: HotkeyShortcut]) {
    self.bindings = Dictionary(
      uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
  }

  public subscript(action: HotkeyAction) -> HotkeyShortcut? {
    get { bindings[action.rawValue] }
    set { bindings[action.rawValue] = newValue }
  }

  public func conflicts(replacing action: HotkeyAction, with shortcut: HotkeyShortcut) -> Bool {
    HotkeyAction.allCases.contains { $0 != action && self[$0] == shortcut }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let decoded = (try? container.decode([String: HotkeyShortcut].self)) ?? [:]
    // Missing actions fall back to their default binding so a payload from an
    // older version still loads; an explicit null clears the binding.
    var merged = Self.defaultBindings.mapKeys()
    for (key, value) in decoded { merged[key] = value }
    // Keys the decoder saw but with no counterpart in defaults stay as-is.
    // Explicitly-unbound defaults: a stored payload that omits an action it
    // knew about cannot be distinguished from an old payload, so unbinding is
    // stored as the sentinel below.
    bindings = merged.filter { $0.value.keyCode != Self.unboundSentinel.keyCode }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    // Store the sentinel for actions that have a default but are unbound, so
    // decode can tell "user cleared this" from "old payload never had it".
    var stored = bindings
    for (key, _) in Self.defaultBindings.mapKeys() where stored[key] == nil {
      stored[key] = Self.unboundSentinel
    }
    try container.encode(stored)
  }

  private static let unboundSentinel = HotkeyShortcut(
    keyCode: 0xFFFE, modifiers: 0, keyLabel: "\u{0}unbound")

  static let defaultBindings: [HotkeyAction: HotkeyShortcut] = [
    .dictationHold: HotkeyShortcut(
      keyCode: 49,
      modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
      keyLabel: "Space"),
    .dictationToggle: HotkeyShortcut(
      keyCode: 49,
      modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue,
      keyLabel: "Space"),
    .cancel: HotkeyShortcut(keyCode: 53, modifiers: 0, keyLabel: "Esc"),
    // ⌃⌥ chords: the global monitor observes keys, it cannot swallow them,
    // and ⌥1 emits "¡" on a US layout — which would replace the user's
    // selection before the polish ever ran. ⌃-chords produce no character.
    .style1: HotkeyShortcut(
      keyCode: 18, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "1"),
    .style2: HotkeyShortcut(
      keyCode: 19, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "2"),
    .style3: HotkeyShortcut(
      keyCode: 20, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "3"),
  ]

  public static let `default` = HotkeyConfiguration(bindings: defaultBindings)
}

extension [HotkeyAction: HotkeyShortcut] {
  fileprivate func mapKeys() -> [String: HotkeyShortcut] {
    let pairs: [(String, HotkeyShortcut)] = map { ($0.key.rawValue, $0.value) }
    return [String: HotkeyShortcut](uniqueKeysWithValues: pairs)
  }
}
