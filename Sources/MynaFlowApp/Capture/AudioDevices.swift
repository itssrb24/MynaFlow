import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
  /// Stable across reboots; persisted as the user's selection.
  let uid: String
  let name: String
  var id: String { uid }
}

enum AudioDevices {
  /// Every audio input macOS exposes, built-in first.
  static func inputs() -> [AudioInputDevice] {
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
    return session.devices.map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
      .sorted { lhs, rhs in
        let lhsBuiltIn = lhs.name.localizedCaseInsensitiveContains("built-in")
        let rhsBuiltIn = rhs.name.localizedCaseInsensitiveContains("built-in")
        if lhsBuiltIn != rhsBuiltIn { return lhsBuiltIn }
        return lhs.name < rhs.name
      }
  }

  /// CoreAudio device id for a capture device UID, for pinning the engine's
  /// input node to a specific microphone.
  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return nil }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
    else { return nil }

    for device in devices {
      var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var deviceUID: Unmanaged<CFString>?
      var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      let status = withUnsafeMutablePointer(to: &deviceUID) {
        AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
      }
      guard status == noErr, let value = deviceUID?.takeRetainedValue() else { continue }
      if String(value) == uid { return device }
    }
    return nil
  }
}
