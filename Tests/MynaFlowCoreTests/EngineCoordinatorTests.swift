import Foundation
import Testing

@testable import MynaFlowCore

private struct StubEngine: SpeechEngine, TranscriptionProviding {
  let id: EngineID
  var available = true
  var result: Result<String, SpeechEngineError>

  var isAvailable: Bool { get async { available } }
  func prepare() async {}
  func transcribe(audio: URL, hints: [String]) async throws -> TranscriptionResult {
    switch result {
    case .success(let text): return TranscriptionResult(text: text, durationSeconds: 1)
    case .failure(let error): throw error
    }
  }
}

private let dummyURL = URL(fileURLWithPath: "/tmp/nonexistent.wav")

@Suite("EngineCoordinator")
struct EngineCoordinatorTests {
  private let apple = StubEngine(id: .apple, result: .success("apple text"))
  private let parakeet = StubEngine(id: .parakeet, result: .success("parakeet text"))

  @Test("Preferred engine wins when it works")
  func preferredWins() async throws {
    let coordinator = EngineCoordinator(primary: parakeet, fallback: apple)
    let outcome = try await coordinator.transcribe(audio: dummyURL, hints: [])
    #expect(outcome.result.text == "parakeet text")
    #expect(outcome.engineUsed == .parakeet)
    #expect(!outcome.fallbackOccurred)
  }

  @Test("Primary failure falls back to Apple silently, flagged in the outcome")
  func primaryFailureFallsBack() async throws {
    var failing = parakeet
    failing.result = .failure(SpeechEngineError("model exploded"))
    let coordinator = EngineCoordinator(primary: failing, fallback: apple)
    let outcome = try await coordinator.transcribe(audio: dummyURL, hints: [])
    #expect(outcome.result.text == "apple text")
    #expect(outcome.engineUsed == .apple)
    #expect(outcome.fallbackOccurred)
  }

  @Test("Primary unavailable (not installed) uses Apple without a fallback flag")
  func primaryUnavailable() async throws {
    var absent = parakeet
    absent.available = false
    let coordinator = EngineCoordinator(primary: absent, fallback: apple)
    let outcome = try await coordinator.transcribe(audio: dummyURL, hints: [])
    #expect(outcome.engineUsed == .apple)
    #expect(!outcome.fallbackOccurred, "an uninstalled engine is not a failure")
  }

  @Test("Both engines failing throws the fallback's error")
  func bothFail() async {
    var failingPrimary = parakeet
    failingPrimary.result = .failure(SpeechEngineError("primary down"))
    var failingFallback = apple
    failingFallback.result = .failure(SpeechEngineError("fallback down"))
    let coordinator = EngineCoordinator(primary: failingPrimary, fallback: failingFallback)
    await #expect(throws: SpeechEngineError.self) {
      _ = try await coordinator.transcribe(audio: dummyURL, hints: [])
    }
  }

  @Test("Primary == fallback engine runs once with no fallback attempt")
  func appleOnly() async throws {
    let coordinator = EngineCoordinator(primary: apple, fallback: apple)
    let outcome = try await coordinator.transcribe(audio: dummyURL, hints: [])
    #expect(outcome.engineUsed == .apple)
    #expect(!outcome.fallbackOccurred)
  }

  @Test("A bare engine satisfies TranscriptionProviding with no fallback flag")
  func bareEngineAdapter() async throws {
    let provider: any TranscriptionProviding = apple
    let outcome = try await provider.transcribe(audio: dummyURL, hints: [])
    #expect(outcome.engineUsed == .apple)
    #expect(!outcome.fallbackOccurred)
    #expect(outcome.result.text == "apple text")
  }
}
