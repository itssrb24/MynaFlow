import AppKit
import Foundation
import Testing

@testable import MynaFlowCore

@Suite("HotkeyShortcut")
struct HotkeyShortcutTests {
  private let commandShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
  private let control = NSEvent.ModifierFlags([.control]).rawValue
  private let controlOption = NSEvent.ModifierFlags([.control, .option]).rawValue

  @Test("Key shortcut matches exact keyCode + normalized modifiers")
  func keyMatch() {
    let shortcut = HotkeyShortcut(keyCode: 49, modifiers: commandShift, keyLabel: "Space")
    #expect(shortcut.matches(keyCode: 49, modifiers: commandShift))
    #expect(!shortcut.matches(keyCode: 48, modifiers: commandShift))
    #expect(!shortcut.matches(keyCode: 49, modifiers: control))
    // Caps lock and other non-shortcut flags are normalized away.
    let withCapsLock = commandShift | NSEvent.ModifierFlags.capsLock.rawValue
    #expect(shortcut.matches(keyCode: 49, modifiers: withCapsLock))
  }

  @Test("Modifier-only shortcut matches the exact set, not supersets")
  func modifierOnlyMatch() {
    let shortcut = HotkeyShortcut.modifierOnly(control)
    #expect(shortcut.isModifierOnly)
    #expect(shortcut.matchesModifiers(control))
    #expect(!shortcut.matchesModifiers(controlOption))
    #expect(!shortcut.matchesModifiers(0))
    // A modifier-only shortcut never matches as a key shortcut.
    #expect(!shortcut.matches(keyCode: 49, modifiers: control))
  }

  @Test("Display names render modifier glyphs")
  func displayNames() {
    let key = HotkeyShortcut(keyCode: 18, modifiers: controlOption, keyLabel: "1")
    #expect(key.displayName == "⌃⌥1")
    let hold = HotkeyShortcut.modifierOnly(control)
    #expect(hold.displayName == "⌃ (hold)")
  }
}

@Suite("HotkeyConfiguration")
struct HotkeyConfigurationTests {
  @Test("Defaults bind hold, toggle, cancel, and the three default styles")
  func defaults() {
    let config = HotkeyConfiguration.default
    #expect(config[.dictationHold] != nil)
    #expect(config[.dictationToggle] != nil)
    #expect(config[.cancel] != nil)
    #expect(config[.style1] != nil)
    #expect(config[.style2] != nil)
    #expect(config[.style3] != nil)
    #expect(config[.style4] == nil)
    #expect(config[.style5] == nil)
    #expect(config[.dictationHold] != config[.dictationToggle])
  }

  @Test("Conflict detection sees other actions' bindings")
  func conflicts() {
    let config = HotkeyConfiguration.default
    let holdShortcut = config[.dictationHold]!
    #expect(config.conflicts(replacing: .dictationToggle, with: holdShortcut))
    #expect(!config.conflicts(replacing: .dictationHold, with: holdShortcut))
    let free = HotkeyShortcut(keyCode: 3, modifiers: 0, keyLabel: "F")
    #expect(!config.conflicts(replacing: .dictationToggle, with: free))
  }

  @Test("Codable round trip preserves bindings including unbound slots")
  func codableRoundTrip() throws {
    var config = HotkeyConfiguration.default
    config[.style4] = HotkeyShortcut(
      keyCode: 21, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "4")
    config[.dictationToggle] = nil
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(HotkeyConfiguration.self, from: data)
    #expect(decoded == config)
    #expect(decoded[.dictationToggle] == nil)
    #expect(decoded[.style4]?.keyLabel == "4")
  }

  @Test("Decoding an empty payload falls back to defaults for missing actions")
  func decodeEmptyPayload() throws {
    let decoded = try JSONDecoder().decode(
      HotkeyConfiguration.self, from: Data("{}".utf8))
    #expect(decoded == .default)
  }
}
