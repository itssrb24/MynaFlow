import Foundation
import Testing

@testable import MynaFlowCore

@Suite("App rules")
struct AppRuleTests {
  private func openStore() async throws -> FlowStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-rules-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite")
    return try await FlowStore.open(at: url)
  }

  @Test("Upsert, read back, and empty rules are removed rather than stored")
  func roundTrip() async throws {
    let store = try await openStore()
    let style = try #require(try await store.styles().first)
    let rule = AppRule(
      bundleID: "com.tinyspeck.slackmacgap", cleanupEnabled: nil, terminalPeriod: false,
      polishStyleID: style.id)
    try await store.upsertAppRule(rule)
    #expect(try await store.appRule(for: "com.tinyspeck.slackmacgap") == rule)
    #expect(try await store.appRules() == [rule])

    try await store.upsertAppRule(AppRule(bundleID: "com.tinyspeck.slackmacgap"))
    #expect(try await store.appRule(for: "com.tinyspeck.slackmacgap") == nil)
    await store.close()
  }

  @Test("Deleting a custom style clears rules that pointed at it")
  func styleDeletionClearsRule() async throws {
    let store = try await openStore()
    let custom = Style(name: "Terse", prompt: "Shorten.", builtin: false)
    try await store.saveStyle(custom)
    try await store.upsertAppRule(AppRule(bundleID: "com.apple.mail", polishStyleID: custom.id))
    try await store.deleteStyle(id: custom.id)
    let rule = try await store.appRule(for: "com.apple.mail")
    // The row survives with the style reference cleared (rule may keep other fields).
    #expect(rule?.polishStyleID == nil)
    await store.close()
  }
}
