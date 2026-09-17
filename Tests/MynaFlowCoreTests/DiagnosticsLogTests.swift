import Foundation
import Testing

@testable import MynaFlowCore

@Suite("DiagnosticsLog")
struct DiagnosticsLogTests {
  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("flow-diag-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("Lines land in an owner-only file with level and category")
  func writesOwnerOnly() throws {
    let log = DiagnosticsLog()
    let directory = temporaryDirectory()
    try log.configure(directory: directory)
    log.write("info", "app", "startup complete")
    let url = try #require(log.fileURL)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(" info [app] startup complete\n"))
    let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o077 == 0)
  }

  @Test("Crossing the size cap rotates once and the export reads oldest first")
  func rotates() throws {
    let log = DiagnosticsLog(maxBytes: 120)
    let directory = temporaryDirectory()
    try log.configure(directory: directory)
    log.write("info", "app", "first line that is fairly long to fill the file quickly")
    log.write("info", "app", "second line that pushes past the cap")
    log.write("info", "app", "third")
    let rotated = try #require(log.rotatedURL)
    #expect(FileManager.default.fileExists(atPath: rotated.path))
    let current = try String(contentsOf: try #require(log.fileURL), encoding: .utf8)
    #expect(!current.contains("first line"))
    let export = String(decoding: log.exportData(), as: UTF8.self)
    let firstRange = try #require(export.range(of: "first line"))
    let thirdRange = try #require(export.range(of: "third"))
    #expect(firstRange.lowerBound < thirdRange.lowerBound)
  }

  @Test("Rotation policy: never rotate an empty file, rotate before exceeding the cap")
  func policy() {
    #expect(!DiagnosticsLog.shouldRotate(currentSize: 0, incoming: 5_000, maxBytes: 100))
    #expect(!DiagnosticsLog.shouldRotate(currentSize: 50, incoming: 50, maxBytes: 100))
    #expect(DiagnosticsLog.shouldRotate(currentSize: 50, incoming: 51, maxBytes: 100))
  }
}
