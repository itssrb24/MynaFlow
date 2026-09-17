import Foundation
import Testing

@testable import MynaFlowCore

@Suite("StreamingWaveWriter")
struct StreamingWaveWriterTests {
  private func frames(count: Int, rate: Double) -> [AudioFrame] {
    (0..<count).map { index in
      AudioFrame(
        samples: (0..<480).map { Float(sin(Double($0 + index * 480) * 0.01)) }, sampleRate: rate)
    }
  }

  @Test("Incremental output is byte-identical to the one-shot encoder at 16 kHz")
  func identicalAt16k() throws {
    let input = frames(count: 20, rate: 16_000)
    let expected = WaveEncoder().encode(input, outputSampleRate: 16_000)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try StreamingWaveWriter(url: url, outputSampleRate: 16_000)
    for frame in input { try writer.append(frame) }
    try writer.finish()
    #expect(try Data(contentsOf: url) == expected)
  }

  @Test("Resampled 48 kHz input matches the one-shot encoder's sample count and header")
  func resampled48k() throws {
    let input = frames(count: 30, rate: 48_000)
    let expected = WaveEncoder().encode(input, outputSampleRate: 16_000)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try StreamingWaveWriter(url: url, outputSampleRate: 16_000)
    for frame in input { try writer.append(frame) }
    try writer.finish()
    let data = try Data(contentsOf: url)
    #expect(data.count == expected.count)
    #expect(data.prefix(44) == expected.prefix(44))
  }

  @Test("Finishing with nothing written yields a valid empty WAV and reports zero seconds")
  func empty() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try StreamingWaveWriter(url: url, outputSampleRate: 16_000)
    try writer.finish()
    #expect(try Data(contentsOf: url).count == 44)
    #expect(writer.durationSeconds == 0)
    #expect(writer.samplesWritten == 0)
  }
}
