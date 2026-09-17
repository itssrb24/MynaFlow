import Foundation

/// Writes a 16-bit mono WAV incrementally so a long dictation never holds
/// its whole recording in memory three times over. Frames are resampled as
/// they arrive; the header is patched with the final sizes on `finish()`.
///
/// Output is byte-identical to `WaveEncoder` for same-rate input. Resampled
/// input differs only in the per-chunk kernel edges, which is inaudible.
public final class StreamingWaveWriter {
  private let handle: FileHandle
  private let outputSampleRate: Int
  public private(set) var samplesWritten = 0
  private var finished = false

  public init(url: URL, outputSampleRate: Int) throws {
    guard FileManager.default.createFile(
      atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    handle = try FileHandle(forWritingTo: url)
    self.outputSampleRate = outputSampleRate
    // Placeholder header; real sizes land in finish().
    try handle.write(contentsOf: Self.header(pcmBytes: 0, sampleRate: outputSampleRate))
  }

  public var durationSeconds: Double {
    Double(samplesWritten) / Double(outputSampleRate)
  }

  public func append(_ frame: AudioFrame) throws {
    guard !finished, !frame.samples.isEmpty else { return }
    let resampled = BandlimitedResampler.resample(
      frame.samples, from: frame.sampleRate, to: Double(outputSampleRate))
    var pcm = Data(capacity: resampled.count * 2)
    for sample in resampled {
      var integer = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
      withUnsafeBytes(of: &integer) { pcm.append(contentsOf: $0) }
    }
    try handle.write(contentsOf: pcm)
    samplesWritten += resampled.count
  }

  public func finish() throws {
    guard !finished else { return }
    finished = true
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Self.header(pcmBytes: samplesWritten * 2, sampleRate: outputSampleRate))
    try handle.close()
  }

  static func header(pcmBytes: Int, sampleRate: Int) -> Data {
    var data = Data()
    func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    data.append("RIFF".data(using: .ascii)!)
    u32(UInt32(36 + pcmBytes))
    data.append("WAVEfmt ".data(using: .ascii)!)
    u32(16)
    u16(1)
    u16(1)
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 2))
    u16(2)
    u16(16)
    data.append("data".data(using: .ascii)!)
    u32(UInt32(pcmBytes))
    return data
  }
}
