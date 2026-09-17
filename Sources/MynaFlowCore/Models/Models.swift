import CryptoKit
import Foundation

public enum ModelKind: String, Codable, Sendable {
  case languageModel
}

/// Why a descriptor was rejected. Descriptors are compiled into the catalog, so
/// these only ever fire on a catalog mistake — the value is in catching that in
/// tests rather than in a message a user would read.
public enum ModelDescriptorError: Error, LocalizedError, Equatable, Sendable {
  case insecureURL
  case untrustedHost(String)
  case malformedChecksum(String)
  case unsafeFileName(String)

  public var errorDescription: String? {
    switch self {
    case .insecureURL: "Model downloads must use https."
    case .untrustedHost(let host): "Model downloads must come from huggingface.co, not \(host)."
    case .malformedChecksum(let value): "Expected a 64-character SHA-256, got \"\(value)\"."
    case .unsafeFileName(let name): "Unsafe model file name \"\(name)\"."
    }
  }
}

public struct ModelDescriptor: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let kind: ModelKind
  public let variant: String
  public let downloadURL: URL
  public let expectedSHA256: String
  public let expectedBytes: Int64
  public let fileName: String
  /// Catalog tier shown to users ("Fastest", "Balanced", "Best quality").
  public let tier: String

  public init(
    id: String,
    displayName: String,
    kind: ModelKind,
    variant: String,
    downloadURL: URL,
    expectedSHA256: String,
    expectedBytes: Int64,
    fileName: String,
    tier: String = ""
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.variant = variant
    self.downloadURL = downloadURL
    self.expectedSHA256 = expectedSHA256.lowercased()
    self.expectedBytes = expectedBytes
    self.fileName = fileName
    self.tier = tier
  }

  /// Human-readable approximate download size ("148 MB", "6.7 GB").
  public var sizeLabel: String {
    ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
  }

  /// Rejects anything unsafe to download or write. Called before every install
  /// and asserted over the whole catalog in tests.
  public func validate() throws(ModelDescriptorError) {
    guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
      throw .unsafeFileName(fileName)
    }
    try Self.validateSource(downloadURL, checksum: expectedSHA256)
  }

  private static func validateSource(_ url: URL, checksum: String) throws(ModelDescriptorError) {
    guard url.scheme == "https" else { throw .insecureURL }
    guard url.host() == "huggingface.co" else { throw .untrustedHost(url.host() ?? "") }
    guard checksum.count == 64, checksum.allSatisfy(\.isHexDigit) else {
      throw .malformedChecksum(checksum)
    }
  }
}

public enum ModelInstallState: Equatable, Sendable {
  case notInstalled
  case checkingDisk
  case downloading(bytesReceived: Int64, totalBytes: Int64)
  case verifying
  case installed
  case failed(message: String)

  /// States that describe work in flight rather than a settled outcome.
  ///
  /// These have to be reconciled against the filesystem, not trusted: a
  /// transient state that never receives its terminal transition would
  /// otherwise pin the UI to a progress bar forever, with a complete file on
  /// disk and no way back short of relaunching.
  public var isTransient: Bool {
    switch self {
    case .checkingDisk, .downloading, .verifying: true
    case .notInstalled, .installed, .failed: false
    }
  }
}

public struct ModelFileVerifier: Sendable {
  public init() {}

  public func sha256Hex(ofFile url: URL, chunkSize: Int = 4 * 1_024 * 1_024) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while true {
      let chunk = try handle.read(upToCount: chunkSize) ?? Data()
      if chunk.isEmpty { break }
      digest.update(data: chunk)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public enum ModelManagerError: Error, LocalizedError, Sendable {
  case insufficientDiskSpace(required: Int64, available: Int64)
  case checksumMismatch
  case invalidDescriptor
  case modelNotInstalled
  /// The connection went silent mid-transfer. Distinct from a network error
  /// because URLSession never raised one: with the task parked, only our own
  /// watchdog notices. Auto-retried; partial progress is kept.
  case downloadStalled

  public var errorDescription: String? {
    switch self {
    case .insufficientDiskSpace(let required, let available):
      "Model needs \(required) bytes but only \(available) bytes are available."
    // Deliberately says the file was discarded and that retrying is the right
    // move, because the old wording ("failed integrity verification") reads as
    // a broken download and invites working around it. Since download URLs pin
    // an immutable revision, a publisher re-upload can no longer cause this;
    // what is left is a corrupted transfer, or bytes that are not the ones
    // Myna checked. The first is worth a retry, the second must never be
    // installed, and the user cannot tell them apart, so the copy asks for a
    // retry and then stops rather than offering an override.
    case .checksumMismatch:
      "This download did not match the fingerprint Myna has for this model, "
        + "so it was discarded and nothing was installed. Usually the transfer "
        + "was corrupted: try again. If it keeps failing, stop and report it "
        + "rather than working around it."
    case .invalidDescriptor: "The model descriptor is incomplete or unsafe."
    case .modelNotInstalled: "The model is not installed."
    case .downloadStalled: "download stalled. Retry keeps your progress."
    }
  }
}
