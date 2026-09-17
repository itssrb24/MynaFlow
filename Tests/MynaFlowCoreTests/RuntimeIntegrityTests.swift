import CryptoKit
import Foundation
import Testing

@testable import MynaFlowCore

@Suite("RuntimeIntegrity")
struct RuntimeIntegrityTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-runtimes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  @Test("Manifest parsing accepts shasum output and ignores junk")
  func parse() {
    let text = """
      # provenance
      \(String(repeating: "a", count: 64))  llama-server
      \(String(repeating: "B", count: 64)) *libggml.dylib
      not a line
      """
    let parsed = RuntimeIntegrity.parse(text)
    #expect(parsed["llama-server"] == String(repeating: "a", count: 64))
    #expect(parsed["libggml.dylib"] == String(repeating: "b", count: 64))
    #expect(parsed.count == 2)
  }

  @Test("Matching files pass; a tampered byte, a missing file, or an unlisted required file fail")
  func verify() throws {
    let dir = try directory()
    let server = Data("server-bytes".utf8)
    let lib = Data("lib-bytes".utf8)
    try server.write(to: dir.appendingPathComponent("llama-server"))
    try lib.write(to: dir.appendingPathComponent("libggml.dylib"))
    let manifest = "\(hex(server))  llama-server\n\(hex(lib))  libggml.dylib\n"
    try manifest.write(to: dir.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)

    #expect(try RuntimeIntegrity.verify(directory: dir, required: ["llama-server"]) == 2)
    #expect(throws: RuntimeIntegrityError.entryMissing("llama-cli")) {
      try RuntimeIntegrity.verify(directory: dir, required: ["llama-cli"])
    }
    try Data("tampered".utf8).write(to: dir.appendingPathComponent("libggml.dylib"))
    #expect(throws: RuntimeIntegrityError.mismatch("libggml.dylib")) {
      try RuntimeIntegrity.verify(directory: dir, required: ["llama-server"])
    }
    try FileManager.default.removeItem(at: dir.appendingPathComponent("llama-server"))
    #expect(throws: RuntimeIntegrityError.fileMissing("llama-server")) {
      try RuntimeIntegrity.verify(directory: dir, required: ["llama-server"])
    }
  }
}
