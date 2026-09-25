import AppKit
import MynaFlowCore

extension PermissionSnapshot {
  /// Reads only; never prompts. Safe before NSApplication exists, which is what
  /// lets `--print-permissions` use it with no UI at all.
  @MainActor
  static func live(permissions: PermissionManager, checkSeal: Bool = false) -> PermissionSnapshot {
    let app =
      (try? CodeIdentity.current(checkSeal: checkSeal))
      ?? CodeIdentity.unreadable(at: Bundle.main.bundleURL)
    let bundleID = Bundle.main.bundleIdentifier ?? "com.itssrb24.MynaFlow"
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return PermissionSnapshot(
      macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
      microphone: permissions.microphoneState,
      accessibility: permissions.hasAccessibilityPermission,
      inputMonitoring: permissions.inputMonitoringState,
      app: app,
      otherCopies: InstalledCopies.find(bundleID: bundleID, excluding: Bundle.main.bundleURL))
  }
}
