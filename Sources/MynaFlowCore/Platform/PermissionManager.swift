import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// The permissions Myna Flow needs — microphone, Accessibility, and Input
/// Monitoring. Deliberately nothing else: no calendar, no screen recording.
@MainActor
public final class PermissionManager {
  public init() {}

  public var hasAccessibilityPermission: Bool {
    AXIsProcessTrusted()
  }

  public var microphoneAuthorization: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  /// Whether the app may *observe* key events from other apps.
  ///
  /// Distinct from Accessibility, and easy to conflate with it. Accessibility
  /// covers reading the accessibility tree and posting events; watching the
  /// keyboard globally — which is the whole of how a hotkey is noticed — is
  /// Input Monitoring. An app with Accessibility but not this one can insert
  /// text perfectly and still never see a shortcut, which looks like the
  /// hotkey being broken rather than a permission being absent.
  public var hasInputMonitoringPermission: Bool {
    IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
  }

  /// Raises the Input Monitoring prompt, and adds the app to the list in
  /// System Settings so it can be switched on even if the prompt is dismissed.
  @discardableResult
  public func requestInputMonitoringPermission() -> Bool {
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
  }

  public func openInputMonitoringSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
  }

  public func requestAccessibilityPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  public func requestMicrophonePermission() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  /// Deep links into the two panes a revoked grant is fixed in.
  public func openAccessibilitySettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  public func openMicrophoneSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
  }

  private func open(_ link: String) {
    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
  }
}
