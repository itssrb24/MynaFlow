import Foundation

/// The polish workload's view of a local language model. Instruction-only:
/// Myna Flow has no meeting pipelines, so the request/response composer layer
/// Myna carries is not ported.
public protocol LocalLanguageModel: Sendable {
  func generateInstruction(_ instruction: String, maxTokens: Int) async throws -> String
}

/// Gemma turn scaffolding shared by the server and CLI transports.
public enum Gemma4PromptAdapter {
  public static func wrap(_ instruction: String) -> String {
    """
    <|turn>system
    Return only the requested final text. Never expose reasoning or control tokens.<turn|>
    <|turn>user
    \(instruction)<turn|>
    <|turn>model
    <|channel>final
    <channel|>

    """
  }

  public static func extractFinalText(from output: String) -> String {
    let content: Substring
    if let marker = output.range(of: "<channel|>", options: .backwards) {
      content = output[marker.upperBound...]
    } else {
      content = output[...]
    }
    return
      content
      .replacingOccurrences(of: "[end of text]", with: "")
      .replacingOccurrences(of: "<end_of_turn>", with: "")
      .replacingOccurrences(of: "<turn|>", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Stop strings that end a Gemma turn — passed to llama-server so generation
/// halts cleanly at the turn boundary.
let gemmaStopTokens = ["<turn|>", "<end_of_turn>", "[end of text]"]

/// A `LocalLanguageModel` backed by the persistent `LlamaServerHost`.
public actor LlamaServerLanguageModel: LocalLanguageModel {
  private let host: LlamaServerHost

  public init(host: LlamaServerHost) {
    self.host = host
  }

  public func generateInstruction(_ instruction: String, maxTokens: Int = 768) async throws
    -> String
  {
    let prompt = Gemma4PromptAdapter.wrap(instruction)
    let raw = try await host.complete(prompt: prompt, maxTokens: maxTokens, stop: gemmaStopTokens)
    let text = Gemma4PromptAdapter.extractFinalText(from: raw)
    guard !text.isEmpty else { throw LlamaServerError.emptyOutput }
    return text
  }
}

/// Cold-spawn `llama-cli` transport — the safety net when the warm server
/// fails. The prompt is handed over on disk (0600 temp file), never argv,
/// where `ps -ww -o args` would show it to every same-user process.
public actor LlamaCLILanguageModel: LocalLanguageModel {
  private let executableURL: URL
  private let modelURL: URL
  private let executor: any ProcessExecuting

  /// A liveness bound, not a performance budget: turns "never" into
  /// "eventually, with an error".
  public static let processTimeout: TimeInterval = 300

  public init(
    executableURL: URL,
    modelURL: URL,
    executor: any ProcessExecuting = LocalProcessExecutor()
  ) {
    self.executableURL = executableURL
    self.modelURL = modelURL
    self.executor = executor
  }

  /// Full Metal offload, flash attention, all-but-two CPU threads.
  private static let performanceArguments: [String] = [
    "--n-gpu-layers", "99",
    "--flash-attn", "on",
    "--threads", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2)),
  ]

  /// Smallest context that comfortably covers prompt + output. Allocating a
  /// KV cache is a fixed per-call tax (~1s measured at 8192 vs 2048).
  static func contextSize(promptLength: Int, maxTokens: Int) -> Int {
    let estimatedTokens = promptLength / 4 + maxTokens + 256
    for size in [2_048, 4_096, 8_192] where estimatedTokens <= size { return size }
    return 8_192
  }

  private func withPromptFile<T: Sendable>(
    _ prompt: String, _ body: (URL) async throws -> T
  ) async throws -> T {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-prompt-\(UUID().uuidString)")
    // Created with its mode, not chmod'd afterwards: a file that is briefly
    // world-readable is world-readable.
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: Data(prompt.utf8),
        attributes: [.posixPermissions: 0o600])
    else { throw LocalProcessError.emptyOutput }
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
  }

  public func generateInstruction(_ instruction: String, maxTokens: Int = 768) async throws
    -> String
  {
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw ModelManagerError.modelNotInstalled
    }
    let prompt = Gemma4PromptAdapter.wrap(instruction)
    let result = try await withPromptFile(prompt) { promptFile in
      try await executor.run(
        executable: executableURL,
        arguments: [
          "--model", modelURL.path,
          "--file", promptFile.path,
          "--n-predict", String(maxTokens),
          "--ctx-size",
          String(Self.contextSize(promptLength: prompt.count, maxTokens: maxTokens)),
          "--temp", "0.2",
          "--no-display-prompt",
          "--simple-io",
          "--no-conversation",
          "--verbosity", "0",
          "--no-log-timestamps",
          "--no-log-prefix",
        ] + Self.performanceArguments,
        standardInput: nil,
        timeout: Self.processTimeout)
    }
    guard result.terminationStatus == 0 else {
      throw LocalProcessError.nonZeroExit(
        status: result.terminationStatus,
        output: SensitiveLogRedactor().redact(result.standardOutput))
    }
    let text = Gemma4PromptAdapter.extractFinalText(from: result.standardOutput)
    guard !text.isEmpty else { throw LocalProcessError.emptyOutput }
    return text
  }
}

/// Chooses the inference transport per call: the warm server when healthy,
/// else a cold-spawned `llama-cli`. A server failure transparently falls back
/// so polish never breaks — the server is retried on the next call.
public actor LanguageModelProvider: LocalLanguageModel {
  private let host: LlamaServerHost
  private let cliExecutableURL: URL
  private var modelURL: URL
  private var warmEnabled: Bool
  private var onFallback: @Sendable () -> Void = {}

  /// Observer fired when the warm server fails and the request is retried
  /// through the cold CLI, so the UI can say why this one is slower.
  public func setFallbackObserver(_ observer: @escaping @Sendable () -> Void) {
    onFallback = observer
  }

  public init(
    host: LlamaServerHost,
    cliExecutableURL: URL,
    modelURL: URL,
    warmEnabled: Bool = true
  ) {
    self.host = host
    self.cliExecutableURL = cliExecutableURL
    self.modelURL = modelURL
    self.warmEnabled = warmEnabled
  }

  public func updateModel(modelURL: URL, modelIdentifier: String) async {
    self.modelURL = modelURL
    await host.update(modelURL: modelURL, modelIdentifier: modelIdentifier)
  }

  public func setIdleTimeout(_ timeout: TimeInterval) async {
    await host.setIdleTimeout(timeout)
  }

  public func stop() async { await host.stop() }

  public var isModelLoaded: Bool {
    get async { await host.isLoaded }
  }

  public var isModelInstalled: Bool {
    FileManager.default.fileExists(atPath: modelURL.path)
  }

  /// Whether a warm-server failure should route this request to the CLI.
  /// User cancellation must propagate, never retry.
  public static func shouldFallBackToCLI(after error: Error) -> Bool {
    if error is LlamaServerError { return true }
    if let urlError = error as? URLError { return urlError.code != .cancelled }
    return false
  }

  public func generateInstruction(_ instruction: String, maxTokens: Int = 768) async throws
    -> String
  {
    guard isModelInstalled else { throw ModelManagerError.modelNotInstalled }
    if warmEnabled {
      do {
        let model = LlamaServerLanguageModel(host: host)
        return try await model.generateInstruction(instruction, maxTokens: maxTokens)
      } catch {
        guard Self.shouldFallBackToCLI(after: error) else { throw error }
        MynaLog.warn("warm instruction failed (\(type(of: error))), CLI fallback")
        onFallback()
      }
    }
    let cli = LlamaCLILanguageModel(executableURL: cliExecutableURL, modelURL: modelURL)
    return try await cli.generateInstruction(instruction, maxTokens: maxTokens)
  }
}
