import Foundation

/// Builds the polish instruction handed to the language model. Pure so the
/// wording — the entire behavior of a style — is under test.
public enum PolishPrompt {
  public static func compose(style: Style, text: String) -> String {
    var sections: [String] = [
      style.prompt,
      "Reply with only the rewritten text — no preamble, no quotes, no commentary.",
    ]
    if !style.examples.isEmpty {
      let rendered = style.examples.map { example in
        "Original: \(example.input)\nRewritten: \(example.output)"
      }.joined(separator: "\n\n")
      sections.append("Examples:\n\(rendered)")
    }
    sections.append("Text to rewrite:\n\(text)")
    return sections.joined(separator: "\n\n")
  }
}

public enum PolishOutcome: Equatable, Sendable {
  case replaced
  case noSelection
  /// The user cancelled while the model was working; nothing was touched.
  case cancelled
  /// The model failed or the replacement could not land. The selection was
  /// left untouched — never replaced with a partial or failed result.
  case failed(String)
}

/// Polish operates on selected text in any app: read the selection via
/// Accessibility, rewrite it in the requested style, replace it in place.
/// The failure contract is absolute: on any error, do nothing to the text.
public actor PolishEngine {
  private let model: any LocalLanguageModel
  private let readSelection: @Sendable () async -> String?
  private let replaceSelection: @Sendable (String) async throws -> TextInsertionResult
  /// Interactive cap: a stalled server must read as a failure in seconds,
  /// not a five-minute hang.
  private let timeout: Duration
  private var generation: Task<String, Error>?
  private var cancelled = false

  public init(
    model: any LocalLanguageModel,
    readSelection: @escaping @Sendable () async -> String?,
    replaceSelection: @escaping @Sendable (String) async throws -> TextInsertionResult,
    timeout: Duration = .seconds(60)
  ) {
    self.model = model
    self.readSelection = readSelection
    self.replaceSelection = replaceSelection
    self.timeout = timeout
  }

  /// Abandons the in-flight rewrite. The selection is never touched.
  public func cancel() {
    cancelled = true
    generation?.cancel()
  }

  public func polish(style: Style) async -> PolishOutcome {
    guard let selection = await readSelection(),
      !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return .noSelection }
    if cancelled { return .cancelled }

    let instruction = PolishPrompt.compose(style: style, text: selection)
    let model = self.model
    let timeout = self.timeout
    let task = Task<String, Error> {
      try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { try await model.generateInstruction(instruction, maxTokens: 1_024) }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw PolishTimeout()
        }
        let first = try await group.next() ?? ""
        group.cancelAll()
        return first
      }
    }
    generation = task
    let rewritten: String
    do {
      rewritten = try await task.value.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch is PolishTimeout {
      return .failed("The model timed out after \(Int(timeout / .seconds(1))) s")
    } catch is CancellationError {
      return .cancelled
    } catch {
      return cancelled ? .cancelled : .failed(error.localizedDescription)
    }
    if cancelled { return .cancelled }
    guard !rewritten.isEmpty else { return .failed("The model returned no text") }

    do {
      let result = try await replaceSelection(rewritten)
      switch result {
      case .replacedSelection, .inserted, .pastedFromClipboard:
        return .replaced
      case .blockedSecureField:
        return .failed("Cannot polish a password field")
      case .copiedToClipboard, .noFocusedField:
        return .failed("Selection changed — rewritten text copied to clipboard")
      }
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}

private struct PolishTimeout: Error {}
