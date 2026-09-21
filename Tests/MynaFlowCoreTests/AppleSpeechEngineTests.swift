import Foundation
import Testing

@testable import MynaFlowCore

/// Transcribes a known phrase straight through the engine.
///
/// The seam the app itself uses is `SpeechEngine.transcribe(audio:hints:)`, a
/// WAV on disk — so a synthesized fixture exercises the real path without a
/// microphone, an audio device, or a human. Acoustic routes cannot cover this
/// on a laptop: the capture path enables voice processing, whose entire job is
/// to cancel audio this Mac just played through its own speakers.
/// Opt-in: `MYNA_SPEECH_E2E=1 swift test`. Apple's speech assets are reserved
/// per process in app context, and a bare test binary reports the engine
/// unavailable, so this cannot run in an ordinary `swift test`.
@Suite("Apple speech engine", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["MYNA_SPEECH_E2E"] == "1"))
struct AppleSpeechEngineTests {
  private static let phrase = "The quick brown fox jumps over the lazy dog."

  private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("myna-speech-\(UUID().uuidString).wav")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["--data-format=LEI16@16000", "-o", url.path, Self.phrase]
    try process.run()
    process.waitUntilExit()
    return url
  }

  @Test("A synthesized sentence comes back as that sentence")
  func transcribesKnownPhrase() async throws {
    let url = try fixture()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.fileExists(atPath: url.path), "say produced no audio")

    let engine = AppleSpeechEngine()
    guard await engine.isAvailable else {
      Issue.record("Apple Speech reports unavailable in this process")
      return
    }
    await engine.prepare()
    let result = try await engine.transcribe(audio: url, hints: [])
    let text = result.text.lowercased()
    #expect(!text.isEmpty, "transcription was empty")
    // Not an exact-match assertion: recognisers punctuate and capitalise as
    // they see fit. The content words are the contract.
    for word in ["quick", "brown", "fox", "lazy", "dog"] {
      #expect(text.contains(word), "expected '\(word)' in: \(result.text)")
    }
  }
}
