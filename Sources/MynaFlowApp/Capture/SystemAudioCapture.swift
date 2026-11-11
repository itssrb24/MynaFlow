import AVFoundation
import CoreAudio
import MynaFlowCore
import os

enum SystemAudioCaptureError: Error, LocalizedError {
  case coreAudio(String, OSStatus)
  case noOutputDevice
  case unsupportedFormat

  var errorDescription: String? {
    switch self {
    case .coreAudio(let step, let status):
      "System audio capture failed (\(step), \(status)). Allow Myna Flow under "
        + "Privacy & Security → Screen & System Audio Recording."
    case .noOutputDevice: "No audio output device to capture from"
    case .unsupportedFormat: "System audio arrived in a format Myna Flow cannot read"
    }
  }
}

/// Captures what the Mac is playing — the other side of a call — with a Core
/// Audio process tap (macOS 14.2+). A global mono tap feeds a private
/// aggregate device whose IO proc delivers frames. Entirely local: a tap is a
/// kernel-side copy of the output mix, nothing touches the network.
///
/// The first start triggers the system "System Audio Recording" prompt
/// (NSAudioCaptureUsageDescription). Teardown destroys the IO proc, the
/// aggregate device and the tap, in that order, on every stop.
@MainActor
final class SystemAudioCapture {
  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "audio")

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private var continuation: AsyncStream<AudioFrame>.Continuation?
  private let queue = DispatchQueue(label: "com.itssrb24.MynaFlow.system-audio", qos: .userInitiated)

  var isRunning: Bool { procID != nil }

  func start() throws -> AsyncStream<AudioFrame> {
    stop()
    do {
      return try startTap()
    } catch {
      stop()
      throw error
    }
  }

  private func startTap() throws -> AsyncStream<AudioFrame> {
    // Exclude nothing: Myna Flow plays no audio of its own while recording.
    let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    description.name = "Myna Flow meeting tap"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

    let outputUID = try Self.defaultOutputDeviceUID()
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Myna Flow Meeting",
      kAudioAggregateDeviceUIDKey: "com.itssrb24.MynaFlow.meeting.\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
      ],
    ]
    try check(
      "create aggregate device",
      AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

    var streamDescription = try Self.tapFormat(tapID)
    guard let format = AVAudioFormat(streamDescription: &streamDescription),
      format.commonFormat == .pcmFormatFloat32
    else { throw SystemAudioCaptureError.unsupportedFormat }

    let stream = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(512)) {
      self.continuation = $0
    }
    let continuation = self.continuation
    let sampleRate = format.sampleRate
    try check(
      "create IO proc",
      AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
        guard
          let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input),
          let frame = Self.monoFrame(buffer, sampleRate: sampleRate)
        else { return }
        continuation?.yield(frame)
      })
    try check("start device", AudioDeviceStart(aggregateID, procID))
    Self.log.info("system audio tap started at \(sampleRate) Hz")
    return stream
  }

  func stop() {
    if let procID {
      AudioDeviceStop(aggregateID, procID)
      AudioDeviceDestroyIOProcID(aggregateID, procID)
    }
    procID = nil
    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
    continuation?.finish()
    continuation = nil
  }

  // MARK: - Helpers

  /// Averages every channel to mono; a mono tap is a straight copy.
  nonisolated private static func monoFrame(_ buffer: AVAudioPCMBuffer, sampleRate: Double)
    -> AudioFrame?
  {
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
    let count = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    let stride = buffer.stride
    var samples = [Float](repeating: 0, count: count)
    for channel in 0..<channelCount {
      let data = channels[channel]
      for index in 0..<count { samples[index] += data[index * stride] }
    }
    if channelCount > 1 {
      let scale = 1 / Float(channelCount)
      for index in 0..<count { samples[index] *= scale }
    }
    return AudioFrame(samples: samples, sampleRate: sampleRate)
  }

  private func check(_ step: String, _ status: OSStatus) throws {
    guard status == noErr else {
      Self.log.error("system audio: \(step) failed: \(status)")
      throw SystemAudioCaptureError.coreAudio(step, status)
    }
  }

  private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
    guard status == noErr else { throw SystemAudioCaptureError.coreAudio("read tap format", status) }
    return format
  }

  private static func defaultOutputDeviceUID() throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
      deviceID != kAudioObjectUnknown
    else { throw SystemAudioCaptureError.noOutputDevice }

    address.mSelector = kAudioDevicePropertyDeviceUID
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
      let uid
    else { throw SystemAudioCaptureError.noOutputDevice }
    return uid.takeRetainedValue() as String
  }
}
