import Foundation
import Testing

@testable import MynaFlowCore

@Suite("StyleShortcuts — which hotkey slot a style's shortcut uses")
struct StyleShortcutsTests {
  func style(_ name: String, slot: Int?) -> Style {
    Style(name: name, prompt: "p", hotkeySlot: slot)
  }

  @Test("a style that already has a slot keeps it")
  func keepsOwnSlot() {
    let formal = style("Formal", slot: 3)
    let styles = [style("Casual", slot: 1), formal]
    #expect(StyleShortcuts.slot(for: formal.id, in: styles) == 3)
  }

  @Test("a style without one gets the first slot no other style uses")
  func firstFreeSlot() {
    let email = style("Email", slot: nil)
    let styles = [style("Casual", slot: 1), style("Formal", slot: 2), style("Notes", slot: 4), email]
    #expect(StyleShortcuts.slot(for: email.id, in: styles) == 3)
  }

  @Test("when all five slots are taken, there is none to give")
  func allTaken() {
    let extra = style("Extra", slot: nil)
    let styles = (1...5).map { style("S\($0)", slot: $0) } + [extra]
    #expect(StyleShortcuts.slot(for: extra.id, in: styles) == nil)
  }

  @Test("a style not in the list yet still gets a free slot")
  func unknownStyle() {
    #expect(StyleShortcuts.slot(for: UUID(), in: [style("Casual", slot: 1)]) == 2)
  }
}
