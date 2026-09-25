import AppKit
import MynaFlowCore

/// Every other bundle Launch Services knows under our bundle id.
///
/// Copies in the Trash, in a clone's dist/ folder, or in Downloads all count:
/// those are exactly the ones that make System Settings show "Myna Flow" as
/// granted while the copy that is actually running is not.
enum InstalledCopies {
  static func find(bundleID: String, excluding selfURL: URL) -> [CodeIdentity] {
    let me = selfURL.standardizedFileURL.resolvingSymlinksInPath()
    return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
      .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
      .filter { $0 != me }
      .map { (try? CodeIdentity.read(at: $0)) ?? CodeIdentity.unreadable(at: $0) }
  }
}
