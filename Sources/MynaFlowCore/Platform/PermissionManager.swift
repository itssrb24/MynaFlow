import AVFoundation
import AppKit
import ApplicationServices
import Foundation

/// The two permissions Myna Flow needs — microphone and Accessibility.
/// Deliberately nothing else: no calendar, no screen recording.
@MainActor
public final class PermissionManager {
  public init() {}

  public var hasAccessibilityPermission: Bool {
    AXIsProcessTrusted()
  }

  public var microphoneAuthorization: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  public func requestAccessibilityPermission() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  public func requestMicrophonePermission() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }
}
