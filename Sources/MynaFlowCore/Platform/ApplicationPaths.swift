import Foundation

/// Locations under ~/Library/Application Support/Myna Flow/. Deliberately a
/// different directory from Myna's so the two apps never share state.
public struct ApplicationPaths: Sendable {
  public static let directoryName = "Myna Flow"

  public let root: URL
  public let models: URL
  public let runtimes: URL
  public let database: URL
  /// Rotating event logs + llama-server stderr tail for diagnostics export.
  public let diagnostics: URL
  /// Scratch space for per-dictation WAVs; contents never outlive a dictation.
  public let scratch: URL

  public init(root: URL) {
    self.root = root
    models = root.appendingPathComponent("Models", isDirectory: true)
    runtimes = root.appendingPathComponent("Runtimes", isDirectory: true)
    database = root.appendingPathComponent("flow.sqlite", isDirectory: false)
    diagnostics = root.appendingPathComponent("Diagnostics", isDirectory: true)
    scratch = root.appendingPathComponent("Scratch", isDirectory: true)
  }

  /// The same locations as `production()` without creating anything. Safe to
  /// call from hot paths such as model-availability probes during view updates.
  public static func resolved(fileManager: FileManager = .default) -> ApplicationPaths? {
    guard
      let applicationSupport = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    else { return nil }
    return ApplicationPaths(
      root: applicationSupport.appendingPathComponent(directoryName, isDirectory: true))
  }

  public static func production(fileManager: FileManager = .default) throws -> ApplicationPaths {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let root = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
    try fileManager.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return ApplicationPaths(root: root)
  }
}
