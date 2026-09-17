import Foundation
import os

/// Append-only, size-rotated event log at `Diagnostics/flow.log`, for the
/// user to export when something misbehaves. Lines carry outcomes and
/// errors, never dictated text; messages pass through the redactor anyway.
public final class DiagnosticsLog: Sendable {
  public static let shared = DiagnosticsLog()
  public static let fileName = "flow.log"
  public static let rotatedFileName = "flow.log.1"

  private struct State {
    var directory: URL?
    var size = 0
  }

  private let maxBytes: Int
  private let state: OSAllocatedUnfairLock<State>
  private let redactor = SensitiveLogRedactor()

  public init(maxBytes: Int = 1_000_000) {
    self.maxBytes = maxBytes
    state = OSAllocatedUnfairLock(initialState: State())
  }

  public var fileURL: URL? {
    state.withLock { $0.directory?.appendingPathComponent(Self.fileName) }
  }

  public var rotatedURL: URL? {
    state.withLock { $0.directory?.appendingPathComponent(Self.rotatedFileName) }
  }

  /// One rotation keeps the previous file; older history is discarded.
  static func shouldRotate(currentSize: Int, incoming: Int, maxBytes: Int) -> Bool {
    currentSize > 0 && currentSize + incoming > maxBytes
  }

  public func configure(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(Self.fileName)
    if !FileManager.default.fileExists(atPath: url.path) {
      _ = FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    state.withLock {
      $0.directory = directory
      $0.size = size
    }
  }

  public func write(_ level: String, _ category: String, _ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(level) [\(category)] \(redactor.redact(message))\n"
    let data = Data(line.utf8)
    state.withLock { current in
      guard let directory = current.directory else { return }
      let url = directory.appendingPathComponent(Self.fileName)
      if Self.shouldRotate(currentSize: current.size, incoming: data.count, maxBytes: maxBytes) {
        let rotated = directory.appendingPathComponent(Self.rotatedFileName)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        _ = FileManager.default.createFile(
          atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        current.size = 0
      }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      guard (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: data)) != nil else { return }
      current.size += data.count
    }
  }

  /// Previous file followed by the current one — oldest lines first.
  public func exportData() -> Data {
    var data = Data()
    for url in [rotatedURL, fileURL].compactMap({ $0 }) {
      if let chunk = try? Data(contentsOf: url) { data.append(chunk) }
    }
    return data
  }
}
