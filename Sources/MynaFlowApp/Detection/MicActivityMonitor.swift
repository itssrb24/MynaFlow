import CoreAudio
import Foundation
import MynaFlowCore

/// Which meeting apps and browsers are using the microphone, or playing
/// audio, right now — from Core Audio's per-process objects (macOS 14.2+).
/// Reads flags only, never any audio, and needs no permission.
enum MicActivityMonitor {
  struct Activity {
    /// Apps using the mic: joining a call.
    let mic: Set<MicHolder>
    /// Apps playing audio: still on a call while the user is muted.
    let playing: Set<MicHolder>
  }

  static func current() -> Activity {
    let snapshot = processes()
    let me = getpid()
    return Activity(
      mic: MeetingApps.micHolders(in: snapshot, excludingPID: me),
      playing: MeetingApps.audioHolders(in: snapshot, excludingPID: me))
  }

  /// Two cheap flags per process every tick; the PID and bundle ID only for
  /// the few that are using the mic or playing audio.
  static func processes() -> [AudioProcessSnapshot] {
    processObjectIDs().compactMap { process in
      let input = read(process, kAudioProcessPropertyIsRunningInput, as: UInt32(0)) != 0
      let output = read(process, kAudioProcessPropertyIsRunningOutput, as: UInt32(0)) != 0
      guard input || output else { return nil }
      return AudioProcessSnapshot(
        pid: read(process, kAudioProcessPropertyPID, as: pid_t(-1)),
        bundleID: bundleID(of: process),
        isRunningInput: input, isRunningOutput: output)
    }
  }

  // MARK: - Core Audio

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private static func processObjectIDs() -> [AudioObjectID] {
    var address = address(kAudioHardwarePropertyProcessObjectList)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  /// A plain-value property (no object references), or `fallback` on error.
  private static func read<T: BitwiseCopyable>(
    _ process: AudioObjectID, _ selector: AudioObjectPropertySelector, as fallback: T
  ) -> T {
    var address = address(selector)
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &value) { buffer in
      AudioObjectGetPropertyData(process, &address, 0, nil, &size, buffer.baseAddress!)
    }
    return status == noErr ? value : fallback
  }

  private static func bundleID(of process: AudioObjectID) -> String? {
    var address = address(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
      let id = value?.takeRetainedValue() as String?, !id.isEmpty
    else { return nil }
    return id
  }
}
