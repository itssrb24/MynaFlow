import AppKit
import Foundation
import Testing

@testable import MynaFlowCore

@Suite("HotkeyRouter")
struct HotkeyRouterTests {
  private let control = NSEvent.ModifierFlags.control.rawValue
  private let controlOption = NSEvent.ModifierFlags([.control, .option]).rawValue

  /// Hold-to-talk on a bare modifier, styles on ⌃⌥1/2 — the configuration
  /// that exposed the swallowed-style bug.
  private func router() -> HotkeyRouter {
    var bindings: [HotkeyAction: HotkeyShortcut] = [
      .dictationHold: HotkeyShortcut(
        keyCode: HotkeyShortcut.modifierOnlyKeyCode, modifiers: NSEvent.ModifierFlags.control.rawValue,
        keyLabel: "Control"),
      .cancel: HotkeyShortcut(keyCode: 53, modifiers: 0, keyLabel: "Esc"),
      .style1: HotkeyShortcut(
        keyCode: 18, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "1"),
    ]
    bindings[.dictationToggle] = HotkeyShortcut(
      keyCode: 49, modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue, keyLabel: "Space")
    return HotkeyRouter(configuration: HotkeyConfiguration(bindings: bindings))
  }

  @Test("A style chord pressed during a bare-modifier hold aborts the hold AND runs the style")
  func styleChordDuringModifierHold() {
    var router = self.router()
    #expect(router.route(.flagsChanged(modifiers: control)) == [.holdDown])
    // ⌥ joins the held ⌃: still a superset, so the hold stands.
    #expect(router.route(.flagsChanged(modifiers: controlOption)) == [])
    // "1" completes ⌃⌥1. The accidental hold must end and the style must fire.
    let effects = router.route(.keyDown(keyCode: 18, modifiers: controlOption, isRepeat: false))
    #expect(effects == [.chordAbort, .action(.style1)])
    #expect(router.isHolding == false)
  }

  @Test("An unrelated chord during a bare-modifier hold aborts the hold and nothing else")
  func unrelatedChordDuringModifierHold() {
    var router = self.router()
    _ = router.route(.flagsChanged(modifiers: control))
    // ⌃C — a copy, not a dictation.
    #expect(router.route(.keyDown(keyCode: 8, modifiers: control, isRepeat: false)) == [.chordAbort])
    #expect(router.isHolding == false)
  }

  @Test("Escape during a modifier hold aborts the hold and cancels")
  func cancelDuringModifierHold() {
    var router = self.router()
    _ = router.route(.flagsChanged(modifiers: control))
    #expect(router.route(.keyDown(keyCode: 53, modifiers: 0, isRepeat: false)) == [.chordAbort, .cancel])
  }

  @Test("A style chord with no hold in progress runs the style on its own")
  func styleChordAlone() {
    var router = self.router()
    #expect(router.route(.keyDown(keyCode: 18, modifiers: controlOption, isRepeat: false)) == [.action(.style1)])
  }

  @Test("Key repeats never re-trigger an action")
  func repeatsIgnored() {
    var router = self.router()
    #expect(router.route(.keyDown(keyCode: 18, modifiers: controlOption, isRepeat: true)) == [])
  }

  @Test("Releasing the held modifier ends the hold exactly once")
  func modifierHoldRelease() {
    var router = self.router()
    #expect(router.route(.flagsChanged(modifiers: control)) == [.holdDown])
    #expect(router.route(.flagsChanged(modifiers: 0)) == [.holdUp])
    #expect(router.route(.flagsChanged(modifiers: 0)) == [])
    #expect(router.isHolding == false)
  }

  @Test("A key-bound hold reports down and up on its own key")
  func keyHold() {
    var bindings: [HotkeyAction: HotkeyShortcut] = [
      .dictationHold: HotkeyShortcut(
        keyCode: 49, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyLabel: "Space")
    ]
    bindings[.style1] = HotkeyShortcut(
      keyCode: 18, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "1")
    var router = HotkeyRouter(configuration: HotkeyConfiguration(bindings: bindings))
    let down = NSEvent.ModifierFlags([.command, .shift]).rawValue
    #expect(router.route(.keyDown(keyCode: 49, modifiers: down, isRepeat: false)) == [.holdDown])
    #expect(router.route(.keyUp(keyCode: 49)) == [.holdUp])
    // A style chord still works after a key hold ended.
    #expect(router.route(.keyDown(keyCode: 18, modifiers: controlOption, isRepeat: false)) == [.action(.style1)])
  }

  @Test("Remapping while a hold is live releases the microphone")
  func remapDuringHold() {
    var router = self.router()
    _ = router.route(.flagsChanged(modifiers: control))
    #expect(router.updateConfiguration(HotkeyConfiguration.default) == [.holdUp])
    #expect(router.isHolding == false)
  }
}
