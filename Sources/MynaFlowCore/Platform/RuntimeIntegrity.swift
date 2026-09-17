import Foundation

public enum RuntimeIntegrityError: Error, Equatable, LocalizedError {
  case manifestMissing
  case entryMissing(String)
  case fileMissing(String)
  case mismatch(String)

  public var errorDescription: String? {
    switch self {
    case .manifestMissing: "The runtime checksum manifest is missing."
    case .entryMissing(let name): "\(name) is not listed in the runtime manifest."
    case .fileMissing(let name): "\(name) is missing from the bundled runtimes."
    case .mismatch(let name): "\(name) does not match its recorded checksum."
    }
  }
}

/// Defense in depth for the one thing Myna Flow executes besides itself:
/// the bundled llama.cpp binaries. Gatekeeper checks the bundle signature at
/// first launch only; this re-checks the files against the manifest sealed
/// at build time before every server spawn.
public enum RuntimeIntegrity {
  public static let manifestName = "SHA256SUMS"

  /// `shasum -a 256` output: "<hex>  <name>" per line, "#" comments allowed.
  public static func parse(_ text: String) -> [String: String] {
    var entries: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
      guard parts.count == 2 else { continue }
      let hex = parts[0].lowercased()
      let name = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
      guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { continue }
      entries[name] = hex
    }
    return entries
  }

  /// Verifies `required` (which must all be listed and present) plus every
  /// other listed file that exists. Returns the number of files checked.
  @discardableResult
  public static func verify(directory: URL, required: [String]) throws -> Int {
    let manifestURL = directory.appendingPathComponent(manifestName)
    guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
      throw RuntimeIntegrityError.manifestMissing
    }
    let manifest = parse(text)
    let verifier = ModelFileVerifier()
    var checked = 0
    for name in required {
      guard let expected = manifest[name] else { throw RuntimeIntegrityError.entryMissing(name) }
      let url = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw RuntimeIntegrityError.fileMissing(name)
      }
      guard try verifier.sha256Hex(ofFile: url) == expected else {
        throw RuntimeIntegrityError.mismatch(name)
      }
      checked += 1
    }
    for (name, expected) in manifest where !required.contains(name) {
      let url = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      guard try verifier.sha256Hex(ofFile: url) == expected else {
        throw RuntimeIntegrityError.mismatch(name)
      }
      checked += 1
    }
    return checked
  }
}
