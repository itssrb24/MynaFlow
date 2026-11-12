import CoreAudio

/// Pulls a process tap's audio out of an aggregate device's input buffer list.
///
/// The list is not just the tap: the aggregate's sub-device input streams come
/// first and tap streams are appended after them. Built-in MacBook speakers,
/// for one, expose a 6-channel sense input, so a mono tap arrives as
/// `[6ch, 1ch]`. The tap is therefore the last buffer with the tap's channel
/// count. Buffers are interleaved Float32 (the tap format is checked when the
/// capture starts).
public enum TapBufferReader {
  public static func monoSamples(
    from buffers: UnsafeMutableAudioBufferListPointer, tapChannels: Int
  ) -> [Float]? {
    guard
      tapChannels > 0,
      let tap = buffers.last(where: { Int($0.mNumberChannels) == tapChannels }),
      let data = tap.mData
    else { return nil }
    let frameCount = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * tapChannels)
    guard frameCount > 0 else { return nil }
    let interleaved = UnsafeBufferPointer(
      start: data.assumingMemoryBound(to: Float.self), count: frameCount * tapChannels)
    guard tapChannels > 1 else { return Array(interleaved) }
    let scale = 1 / Float(tapChannels)
    return (0..<frameCount).map { frame in
      let base = frame * tapChannels
      return interleaved[base..<base + tapChannels].reduce(0, +) * scale
    }
  }
}
