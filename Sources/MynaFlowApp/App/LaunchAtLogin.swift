import ServiceManagement

/// Login-item registration through SMAppService — the supported, prompt-free
/// path for a bundled app (no helper, no AppleScript).
enum LaunchAtLogin {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
