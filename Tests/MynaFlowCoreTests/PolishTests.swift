import Foundation
import Testing

@testable import MynaFlowCore

@Suite("PolishPrompt")
struct PolishPromptTests {
  @Test("Composes style prompt, text, and the only-output contract")
  func basicComposition() {
    let style = Style(name: "Formal", prompt: "Rewrite formally.")
    let instruction = PolishPrompt.compose(style: style, text: "hey what's up")
    #expect(instruction.contains("Rewrite formally."))
    #expect(instruction.contains("hey what's up"))
    #expect(instruction.contains("Reply with only the rewritten text"))
  }

  @Test("Example pairs are included when present")
  func examples() {
    var style = Style(name: "Casual", prompt: "Relax it.")
    style.examples = [
      StyleExample(input: "Greetings to you.", output: "Hey there!")
    ]
    let instruction = PolishPrompt.compose(style: style, text: "Good day.")
    #expect(instruction.contains("Greetings to you."))
    #expect(instruction.contains("Hey there!"))
    // The example section precedes the actual text.
    let exampleIndex = instruction.range(of: "Hey there!")!.lowerBound
    let textIndex = instruction.range(of: "Good day.")!.lowerBound
    #expect(exampleIndex < textIndex)
  }
}

@Suite("PolishEngine")
struct PolishEngineTests {
  private final class Replacements: @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []
    func append(_ text: String) {
      lock.lock()
      _texts.append(text)
      lock.unlock()
    }
    var texts: [String] {
      lock.lock()
      defer { lock.unlock() }
      return _texts
    }
  }

  private struct FakeModel: LocalLanguageModel {
    var result: Result<String, LlamaServerError>
    func generateInstruction(_ instruction: String, maxTokens: Int) async throws -> String {
      try result.get()
    }
  }

  @Test("Success replaces the selection with the model output")
  func success() async throws {
    let replacements = Replacements()
    let engine = PolishEngine(
      model: FakeModel(result: .success("Refined text.")),
      readSelection: { "raw text" },
      replaceSelection: { text in
        replacements.append(text)
        return .replacedSelection
      })
    let outcome = await engine.polish(style: Style(name: "Formal", prompt: "p"))
    #expect(outcome == .replaced)
    #expect(replacements.texts == ["Refined text."])
  }

  @Test("Model failure leaves the selection untouched")
  func modelFailure() async throws {
    let replacements = Replacements()
    let engine = PolishEngine(
      model: FakeModel(result: .failure(.emptyOutput)),
      readSelection: { "raw text" },
      replaceSelection: { text in
        replacements.append(text)
        return .replacedSelection
      })
    let outcome = await engine.polish(style: Style(name: "Formal", prompt: "p"))
    guard case .failed = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(replacements.texts.isEmpty, "failed polish must never touch the selection")
  }

  @Test("No selection is reported without calling the model")
  func noSelection() async throws {
    let engine = PolishEngine(
      model: FakeModel(result: .success("never used")),
      readSelection: { nil },
      replaceSelection: { _ in .replacedSelection })
    let outcome = await engine.polish(style: Style(name: "Formal", prompt: "p"))
    #expect(outcome == .noSelection)
  }

  private struct HangingModel: LocalLanguageModel {
    func generateInstruction(_ instruction: String, maxTokens: Int) async throws -> String {
      try await Task.sleep(for: .seconds(30))
      return "never"
    }
  }

  @Test("Cancel while the model is thinking leaves the selection untouched")
  func cancelMidPolish() async throws {
    let replacements = Replacements()
    let engine = PolishEngine(
      model: HangingModel(),
      readSelection: { "raw text" },
      replaceSelection: { text in
        replacements.append(text)
        return .replacedSelection
      })
    async let outcome = engine.polish(style: Style(name: "Formal", prompt: "p"))
    try await Task.sleep(for: .milliseconds(50))
    await engine.cancel()
    let result = await outcome
    #expect(result == .cancelled)
    #expect(replacements.texts.isEmpty)
  }

  @Test("A model that never answers is cut off at the interactive timeout")
  func timeout() async throws {
    let replacements = Replacements()
    let engine = PolishEngine(
      model: HangingModel(),
      readSelection: { "raw text" },
      replaceSelection: { text in
        replacements.append(text)
        return .replacedSelection
      },
      timeout: .milliseconds(100))
    let started = ContinuousClock.now
    let outcome = await engine.polish(style: Style(name: "Formal", prompt: "p"))
    #expect(ContinuousClock.now - started < .seconds(5))
    guard case .failed(let message) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(message.lowercased().contains("timed out"))
    #expect(replacements.texts.isEmpty)
  }

  @Test("Whitespace-only selection counts as no selection")
  func whitespaceSelection() async throws {
    let engine = PolishEngine(
      model: FakeModel(result: .success("never used")),
      readSelection: { "   \n" },
      replaceSelection: { _ in .replacedSelection })
    let outcome = await engine.polish(style: Style(name: "Formal", prompt: "p"))
    #expect(outcome == .noSelection)
  }
}

@Suite("FlowStore styles v2")
struct FlowStoreStyleTests {
  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-style-tests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("flow.sqlite", isDirectory: false)
  }

  @Test("Schema migrates to v2 and seeded styles carry empty examples")
  func migratesToV2() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    #expect(await store.schemaVersion() == 4)
    let styles = try await store.styles()
    #expect(styles.allSatisfy { $0.examples.isEmpty })
    await store.close()
  }

  @Test("Custom styles round-trip with examples and can be deleted")
  func customStyleRoundTrip() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    var style = Style(name: "Pirate", prompt: "Arr.", hotkeySlot: 4)
    style.examples = [StyleExample(input: "Hello.", output: "Ahoy!")]
    try await store.saveStyle(style)
    let loaded = try #require(try await store.styles().first { $0.id == style.id })
    #expect(loaded.examples == style.examples)
    #expect(loaded.hotkeySlot == 4)

    // Save again (update) — no duplicate.
    style.prompt = "Arr, matey."
    try await store.saveStyle(style)
    let all = try await store.styles()
    #expect(all.filter { $0.id == style.id }.count == 1)

    try await store.deleteStyle(id: style.id)
    #expect(try await store.styles().first { $0.id == style.id } == nil)
    await store.close()
  }

  @Test("Built-in styles cannot be deleted and are seeded only into an empty table")
  func builtinGuard() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    let casual = try #require(try await store.styles().first { $0.name == "Casual" })
    await #expect(throws: FlowStoreError.self) { try await store.deleteStyle(id: casual.id) }
    #expect(try await store.styles().contains { $0.id == casual.id })

    // A user who deleted every custom style and re-slotted a built-in must
    // not get the seed re-run on top of their arrangement.
    var moved = casual
    moved.hotkeySlot = 5
    try await store.saveStyle(moved)
    await store.close()
    let reopened = try await FlowStore.open(at: store.databaseURL)
    let slots = try await reopened.styles().filter { $0.name == "Casual" }.map(\.hotkeySlot)
    #expect(slots == [5])
    await reopened.close()
  }

  @Test("Style lookup by hotkey slot")
  func slotLookup() async throws {
    let store = try await FlowStore.open(at: temporaryDatabaseURL())
    // Built-ins are seeded into slots 1–3.
    let casual = try #require(try await store.style(forSlot: 1))
    #expect(casual.name == "Casual")
    #expect(try await store.style(forSlot: 5) == nil)
    await store.close()
  }
}
