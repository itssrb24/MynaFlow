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

  /// Removes anything left in the scratch directory.
  ///
  /// Scratch holds one WAV per dictation and nothing else, and every normal
  /// path deletes it. A crash, a force-quit, or quitting mid-recording can
  /// still strand one, and recorded audio is the last thing that should
  /// linger, so the invariant is re-established at launch rather than assumed.
  @discardableResult
  public func clearScratch(fileManager: FileManager = .default) -> Int {
    guard let contents = try? fileManager.contentsOfDirectory(
      at: scratch, includingPropertiesForKeys: nil)
    else { return 0 }
    var removed = 0
    for url in contents where (try? fileManager.removeItem(at: url)) != nil {
      removed += 1
    }
    return removed
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
    let paths = ApplicationPaths(root: root)
    // Create, then re-assert: creation attributes do nothing for a directory
    // that already exists with looser bits.
    for directory in [root, paths.models, paths.scratch, paths.diagnostics, paths.runtimes] {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    return paths
  }
}
