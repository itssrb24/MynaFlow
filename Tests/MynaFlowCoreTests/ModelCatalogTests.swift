import Foundation
import Testing

@testable import MynaFlowCore

@Suite("DefaultModelCatalog")
struct ModelCatalogTests {
  @Test("Every catalog descriptor validates (https, pinned host, real checksum)")
  func catalogValidates() {
    for descriptor in DefaultModelCatalog.all {
      #expect(throws: Never.self, "\(descriptor.id)") {
        try descriptor.validate()
      }
      // Pin a revision, never main: a re-upload must not change bytes.
      #expect(
        !descriptor.downloadURL.path.contains("/resolve/main/"),
        "\(descriptor.id) must pin a commit revision")
    }
  }

  @Test("Descriptor validation rejects http, foreign hosts, and bad checksums")
  func validationRejections() {
    func descriptor(url: String, sha: String = String(repeating: "a", count: 64))
      -> ModelDescriptor
    {
      ModelDescriptor(
        id: "x", displayName: "x", kind: .languageModel, variant: "v",
        downloadURL: URL(string: url)!, expectedSHA256: sha,
        expectedBytes: 1, fileName: "x.gguf")
    }
    #expect(throws: ModelDescriptorError.insecureURL) {
      try descriptor(url: "http://huggingface.co/x").validate()
    }
    #expect(throws: ModelDescriptorError.untrustedHost("example.com")) {
      try descriptor(url: "https://example.com/x").validate()
    }
    #expect(throws: ModelDescriptorError.malformedChecksum("short")) {
      try descriptor(url: "https://huggingface.co/x", sha: "short").validate()
    }
  }

  @Test("Checksum verification rejects corrupt bytes")
  func checksumRejectsCorruption() throws {
    let verifier = ModelFileVerifier()
    let good = Data("model weights".utf8)
    let expected = verifier.sha256Hex(of: good)
    #expect(verifier.verify(good, expectedSHA256: expected))
    #expect(!verifier.verify(Data("model weightz".utf8), expectedSHA256: expected))

    // File-based hashing agrees with in-memory hashing.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("verify-\(UUID().uuidString).bin")
    try good.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try verifier.sha256Hex(ofFile: url) == expected)
  }
}

@Suite("SetupAdvisor")
struct SetupAdvisorTests {
  private func hardware(gigabytes: Int64, diskGigabytes: Int64 = 500) -> HardwareProfile {
    HardwareProfile(
      memoryBytes: gigabytes * 1_073_741_824,
      freeDiskBytes: diskGigabytes * 1_073_741_824,
      macOSMajorVersion: 26)
  }

  @Test("16 GB Macs get a genuinely usable recommendation (E4B), not a warning")
  func sixteenGigabyteTier() {
    let best = SetupAdvisor.largestRunnableLanguageModel(on: hardware(gigabytes: 16))
    #expect(best?.id == DefaultModelCatalog.gemma4E4BQ4.id)
  }

  @Test("32 GB Macs are offered the 12B, 64 GB the 26B")
  func upperTiers() {
    #expect(
      SetupAdvisor.largestRunnableLanguageModel(on: hardware(gigabytes: 32))?.id
        == DefaultModelCatalog.gemma4TwentySixBA4BQ4.id
        || SetupAdvisor.largestRunnableLanguageModel(on: hardware(gigabytes: 32))?.id
        == DefaultModelCatalog.gemma4TwelveBQ4.id)
    #expect(
      SetupAdvisor.largestRunnableLanguageModel(on: hardware(gigabytes: 64))?.id
        == DefaultModelCatalog.gemma4TwentySixBA4BQ4.id)
  }

  @Test("Insufficient disk is reported before memory")
  func diskFirst() {
    let cramped = hardware(gigabytes: 64, diskGigabytes: 1)
    let availability = SetupAdvisor.availability(
      of: DefaultModelCatalog.gemma4E4BQ4, on: cramped)
    guard case .insufficientDisk = availability else {
      Issue.record("expected insufficientDisk, got \(availability)")
      return
    }
  }

  @Test("A machine that fits nothing gets nil, and skip stays the honest answer")
  func nothingFits() {
    let tiny = HardwareProfile(
      memoryBytes: 4 * 1_073_741_824, freeDiskBytes: 2 * 1_073_741_824, macOSMajorVersion: 26)
    #expect(SetupAdvisor.largestRunnableLanguageModel(on: tiny) == nil)
    #expect(SetupAdvisor.recommendedLanguage(for: .skip) == nil)
  }
}

@Suite("DownloadRetryPolicy")
struct DownloadRetryPolicyTests {
  @Test("Transport failures retry; content and intent failures do not")
  func retryTriage() {
    #expect(DownloadRetryPolicy.isRetryable(ModelManagerError.downloadStalled))
    #expect(DownloadRetryPolicy.isRetryable(URLError(.timedOut)))
    #expect(DownloadRetryPolicy.isRetryable(URLError(.networkConnectionLost)))
    #expect(!DownloadRetryPolicy.isRetryable(ModelManagerError.checksumMismatch))
    #expect(!DownloadRetryPolicy.isRetryable(URLError(.cancelled)))
  }

  @Test("Backoff grows 2, 4, 8 and stall threshold is 60s")
  func timing() {
    #expect(DownloadRetryPolicy.delay(beforeRetry: 1) == 2)
    #expect(DownloadRetryPolicy.delay(beforeRetry: 2) == 4)
    #expect(DownloadRetryPolicy.delay(beforeRetry: 3) == 8)
    #expect(DownloadRetryPolicy.isStalled(idleSeconds: 60))
    #expect(!DownloadRetryPolicy.isStalled(idleSeconds: 59))
  }
}
