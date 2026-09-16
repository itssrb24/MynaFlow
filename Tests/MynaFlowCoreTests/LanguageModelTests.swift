import Foundation
import Testing

@testable import MynaFlowCore

@Suite("Gemma4PromptAdapter")
struct GemmaAdapterTests {
  @Test("Wrap embeds the instruction inside the turn scaffolding")
  func wrap() {
    let prompt = Gemma4PromptAdapter.wrap("Rewrite this.")
    #expect(prompt.contains("Rewrite this.<turn|>"))
    #expect(prompt.hasSuffix("<channel|>\n"))
  }

  @Test("ExtractFinalText strips control tokens and takes the final channel")
  func extract() {
    let raw = "thinking noise<channel|>\nHello world.<end_of_turn>[end of text]"
    #expect(Gemma4PromptAdapter.extractFinalText(from: raw) == "Hello world.")
    // No channel marker: whole output, trimmed.
    #expect(Gemma4PromptAdapter.extractFinalText(from: "  plain \n") == "plain")
  }
}

@Suite("SSEEvent")
struct SSEEventTests {
  @Test("Parses content, stop, and ignores non-data lines")
  func parsing() {
    #expect(SSEEvent.parse(#"data: {"content":"tok"}"#) == .content("tok"))
    #expect(SSEEvent.parse(#"data: {"content":"","stop":true}"#) == .stop)
    #expect(SSEEvent.parse(": keep-alive") == nil)
    #expect(SSEEvent.parse("") == nil)
    #expect(SSEEvent.parse("data: not-json") == nil)
  }
}

@Suite("LlamaServerHost policies")
struct LlamaServerPolicyTests {
  @Test("Idle unload fires only at or past the timeout")
  func idlePolicy() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    #expect(
      LlamaServerHost.shouldUnload(
        now: base.addingTimeInterval(300), lastUsed: base, idleTimeout: 300))
    #expect(
      !LlamaServerHost.shouldUnload(
        now: base.addingTimeInterval(299), lastUsed: base, idleTimeout: 300))
  }

  @Test("Listening-port parser accepts only the exact announcement line")
  func portParsing() {
    let valid = "9.99.999.999 I srv  llama_server: listening on http://127.0.0.1:52345\n"
    #expect(LlamaServerHost.reportedListeningPort(in: valid) == 52_345)
    // Incomplete final line (no trailing newline) must be ignored.
    let partial = "9.99.999.999 I srv  llama_server: listening on http://127.0.0.1:52345"
    #expect(LlamaServerHost.reportedListeningPort(in: partial) == nil)
    // A forged host must not match.
    let forged = "9.99.999.999 I srv  llama_server: listening on http://0.0.0.0:52345\n"
    #expect(LlamaServerHost.reportedListeningPort(in: forged) == nil)
  }

  @Test("Orphan pkill pattern escapes regex metacharacters and anchors argv[0]")
  func orphanPattern() {
    let pattern = LlamaServerHost.orphanProcessPattern(
      executablePath: "/Users/x/Library/App Support (1)/llama-server")
    #expect(pattern.hasPrefix("^"))
    #expect(pattern.contains(#"\("#))
    #expect(pattern.hasSuffix("( |$)"))
  }

  @Test("Server arguments bind loopback with an OS-assigned port")
  func serverArguments() {
    let config = LlamaServerHost.Configuration(
      executableURL: URL(fileURLWithPath: "/tmp/llama-server"),
      modelURL: URL(fileURLWithPath: "/tmp/model.gguf"),
      modelIdentifier: "test")
    let arguments = LlamaServerHost.serverArguments(configuration: config)
    #expect(arguments.contains("127.0.0.1"))
    let portIndex = try? #require(arguments.firstIndex(of: "--port"))
    #expect(portIndex.map { arguments[$0 + 1] } == "0")
    #expect(arguments.contains("--no-webui"))
  }
}

@Suite("LanguageModelProvider policies")
struct ProviderPolicyTests {
  @Test("Server errors and non-cancel URL errors fall back to CLI; cancellation propagates")
  func fallbackPolicy() {
    #expect(LanguageModelProvider.shouldFallBackToCLI(after: LlamaServerError.healthTimeout))
    #expect(
      LanguageModelProvider.shouldFallBackToCLI(after: URLError(.cannotConnectToHost)))
    #expect(!LanguageModelProvider.shouldFallBackToCLI(after: URLError(.cancelled)))
    #expect(!LanguageModelProvider.shouldFallBackToCLI(after: CancellationError()))
  }
}

@Suite("LlamaCLILanguageModel policies")
struct CLIPolicyTests {
  @Test("Context size steps up with prompt length and never exceeds 8192")
  func contextSize() {
    #expect(LlamaCLILanguageModel.contextSize(promptLength: 400, maxTokens: 256) == 2_048)
    #expect(LlamaCLILanguageModel.contextSize(promptLength: 10_000, maxTokens: 512) == 4_096)
    #expect(LlamaCLILanguageModel.contextSize(promptLength: 60_000, maxTokens: 512) == 8_192)
    #expect(LlamaCLILanguageModel.contextSize(promptLength: 500_000, maxTokens: 512) == 8_192)
  }
}
