import Foundation
import Testing

@testable import MynaFlowCore

/// The app has no language picker, so this mapping is the entire answer to
/// "what language does Myna Flow transcribe?". Fixture is the real supported
/// set, measured from SpeechTranscriber.supportedLocales on macOS 26.4.
@Suite("SpeechLocaleResolver")
struct SpeechLocaleResolverTests {
  private static let appleSupported = [
    "de_AT", "de_CH", "de_DE",
    "en_AU", "en_CA", "en_GB", "en_IE", "en_IN", "en_NZ", "en_SG", "en_US", "en_ZA",
    "es_CL", "es_ES", "es_MX", "es_US",
    "fr_BE", "fr_CA", "fr_CH", "fr_FR",
    "it_CH", "it_IT",
    "ja_JP", "ko_KR",
    "pt_BR", "pt_PT",
    "yue_CN", "zh_CN", "zh_HK", "zh_TW",
  ]

  private func resolve(
    _ preferred: [String], region: String? = nil, supported: [String]? = nil
  ) -> String {
    SpeechLocaleResolver.resolve(
      preferredLanguages: preferred, regionHint: region,
      supported: supported ?? Self.appleSupported)
  }

  @Test(
    "Resolution table",
    arguments: [
      // Exact matches and normalization (hyphen/underscore/case)
      (["en-US"], "US", "en_US"),
      (["en_US"], "US", "en_US"),
      (["EN-us"], "US", "en_US"),
      // Non-default variants preserved
      (["en-GB"], "GB", "en_GB"),
      (["fr-CH"], "CH", "fr_CH"),
      (["de-AT"], "AT", "de_AT"),
      (["es-MX"], "MX", "es_MX"),
      // Language only → default region table, not alphabetical
      (["en"], nil, "en_US"),
      (["fr"], nil, "fr_FR"),
      (["pt"], nil, "pt_BR"),
      (["zh"], nil, "zh_CN"),
      // Region hint beats the default table
      (["en"], "AU", "en_AU"),
      // Unsupported region falls back to the default variant
      (["en-DE"], "DE", "en_US"),
      (["fr-MA"], "MA", "fr_FR"),
      (["pt-AO"], "AO", "pt_BR"),
      // Script and variant subtags ignored
      (["zh-Hans-CN"], "CN", "zh_CN"),
      (["zh-Hant-TW"], "TW", "zh_TW"),
      (["yue-Hans-CN"], "CN", "yue_CN"),
      (["en-US-POSIX"], "US", "en_US"),
      // UN M.49 Latin America alias
      (["es-419"], "419", "es_MX"),
      // Fallbacks
      (["nl-NL"], "NL", "en_US"),
      (["nl-NL", "fr-FR"], "NL", "fr_FR"),
      ([], nil, "en_US"),
    ] as [([String], String?, String)])
  func table(preferred: [String], region: String?, expected: String) {
    #expect(resolve(preferred, region: region) == expected)
  }

  @Test("Empty supported set still returns something")
  func emptySupportedSet() {
    #expect(resolve(["en-US"], region: "US", supported: []) == "en-US")
  }

  @Test("Fallback is deterministic when en_US is absent")
  func deterministicWithoutEnglishUS() {
    let without = Self.appleSupported.filter { $0 != "en_US" }
    let picked = resolve(["nl-NL"], region: "NL", supported: without)
    #expect(without.contains(picked))
    #expect(picked == resolve(["nl-NL"], region: "NL", supported: without))
  }

  @Test("Result is always drawn from the supported set")
  func alwaysSupported() {
    let inputs: [[String]] = [
      ["en-US"], ["en"], ["fr"], ["zh-Hans-CN"], ["nl-NL"], ["es-419"], ["yue"], [],
    ]
    for input in inputs {
      let picked = resolve(input, region: "US")
      #expect(Self.appleSupported.contains(picked), "\(input) resolved to \(picked)")
    }
  }
}

@Suite("BiasTerms")
struct BiasTermsTests {
  @Test("Sanitize trims, drops blanks, dedupes case-insensitively, caps at limit")
  func sanitize() {
    let terms = ["  Kubernetes ", "", "kubernetes", "GRDB", "   ", "Parakeet"]
    #expect(BiasTerms.sanitize(terms) == ["Kubernetes", "GRDB", "Parakeet"])
    #expect(BiasTerms.sanitize(terms, limit: 2) == ["Kubernetes", "GRDB"])
    #expect(BiasTerms.sanitize(terms, limit: 0) == [])
  }

  @Test("Split accepts commas and newlines")
  func split() {
    #expect(BiasTerms.split("alpha, beta\ngamma , ") == ["alpha", "beta", "gamma"])
  }
}

@Suite("WaveEncoder")
struct WaveEncoderTests {
  @Test("Encodes 16-bit mono PCM WAV with a correct header")
  func header() {
    let frames = [AudioFrame(samples: [0, 0.5, -0.5, 1], sampleRate: 16_000)]
    let data = WaveEncoder().encode(frames, outputSampleRate: 16_000)
    #expect(data.count == 44 + 8)  // header + 4 samples * 2 bytes
    #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
    #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
    // Sample rate at offset 24, little-endian.
    let rate = data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    #expect(UInt32(littleEndian: rate) == 16_000)
  }

  @Test("48k input downsamples to a third of the samples at 16k")
  func downsampling() {
    let samples = [Float](repeating: 0.25, count: 4_800)
    let frames = [AudioFrame(samples: samples, sampleRate: 48_000)]
    let data = WaveEncoder().encode(frames, outputSampleRate: 16_000)
    let pcmBytes = data.count - 44
    #expect(pcmBytes == 1_600 * 2)
  }
}
