import CoreAudio
import Testing

@testable import MynaFlowCore

/// Builds an AudioBufferList of interleaved Float32 buffers, runs `body`,
/// then frees everything.
private func withBufferList<T>(
  _ buffers: [(channels: UInt32, samples: [Float])],
  _ body: (UnsafeMutableAudioBufferListPointer) -> T
) -> T {
  let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
  var storage: [UnsafeMutablePointer<Float>] = []
  for (index, buffer) in buffers.enumerated() {
    let data = UnsafeMutablePointer<Float>.allocate(capacity: max(buffer.samples.count, 1))
    data.initialize(from: buffer.samples, count: buffer.samples.count)
    storage.append(data)
    list[index] = AudioBuffer(
      mNumberChannels: buffer.channels,
      mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
      mData: UnsafeMutableRawPointer(data))
  }
  defer {
    storage.forEach { $0.deallocate() }
    free(list.unsafeMutablePointer)
  }
  return body(list)
}

@Suite("Tap buffer reader")
struct TapBufferReaderTests {
  @Test("Reads the tap buffer that follows a sub-device's input stream")
  func skipsSubDeviceInput() {
    // Built-in speakers expose a 6-channel sense input ahead of the tap.
    let sense = [Float](repeating: 0.9, count: 6 * 4)
    let tap: [Float] = [0.1, -0.2, 0.3, -0.4]
    let samples = withBufferList([(6, sense), (1, tap)]) {
      TapBufferReader.monoSamples(from: $0, tapChannels: 1)
    }
    #expect(samples == tap)
  }

  @Test("A lone mono tap buffer is copied straight through")
  func loneMonoBuffer() {
    let tap: [Float] = [0.5, 0.25]
    let samples = withBufferList([(1, tap)]) {
      TapBufferReader.monoSamples(from: $0, tapChannels: 1)
    }
    #expect(samples == tap)
  }

  @Test("An interleaved stereo tap is averaged to mono")
  func stereoMixdown() {
    let interleaved: [Float] = [0.2, 0.4, -0.6, -0.2]
    let samples = withBufferList([(2, interleaved)]) {
      TapBufferReader.monoSamples(from: $0, tapChannels: 2)
    }
    #expect(samples?.count == 2)
    #expect(abs((samples?[0] ?? 0) - 0.3) < 0.0001)
    #expect(abs((samples?[1] ?? 0) + 0.4) < 0.0001)
  }

  @Test("No buffer with the tap's channel count yields nil")
  func noMatchingBuffer() {
    let samples = withBufferList([(6, [Float](repeating: 0, count: 12))]) {
      TapBufferReader.monoSamples(from: $0, tapChannels: 1)
    }
    #expect(samples == nil)
  }

  @Test("An empty tap buffer yields nil")
  func emptyBuffer() {
    let samples = withBufferList([(1, [])]) {
      TapBufferReader.monoSamples(from: $0, tapChannels: 1)
    }
    #expect(samples == nil)
  }
}
