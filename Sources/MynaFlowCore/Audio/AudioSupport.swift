import Foundation

public struct AudioFrame: Sendable {
  public let samples: [Float]
  public let sampleRate: Double

  public init(samples: [Float], sampleRate: Double) {
    self.samples = samples
    self.sampleRate = sampleRate
  }
}

/// Band-limited sinc resampler. Linear interpolation degenerates to bare
/// decimation at integer ratios (48k→16k), aliasing everything above the
/// target Nyquist into the audible band.
public enum BandlimitedResampler {
  /// Half-width of the sinc kernel in source samples. 16 taps each side puts
  /// alias rejection past 60 dB with a Blackman window — inaudible — while a
  /// 45-second chunk still converts in milliseconds.
  private static let halfTaps = 16

  public static func resample(
    _ samples: [Float], from sourceRate: Double, to targetRate: Double
  ) -> [Float] {
    guard !samples.isEmpty else { return [] }
    guard abs(sourceRate - targetRate) > 1 else { return samples }

    let ratio = sourceRate / targetRate
    // Cutoff at 90% of the tighter Nyquist, in cycles per SOURCE sample.
    let cutoff = 0.45 * min(1, targetRate / sourceRate)
    let outputCount = Int(Double(samples.count) / ratio)
    guard outputCount > 0 else { return [] }

    var output = [Float](repeating: 0, count: outputCount)
    let taps = Double(halfTaps)
    for index in 0..<outputCount {
      let center = Double(index) * ratio
      let first = max(0, Int(center) - halfTaps + 1)
      let last = min(samples.count - 1, Int(center) + halfTaps)
      var accumulated = 0.0
      var weightSum = 0.0
      for sourceIndex in first...last {
        let distance = center - Double(sourceIndex)
        // Blackman-windowed sinc low-pass evaluated at a continuous offset.
        let window =
          0.42 + 0.5 * cos(.pi * distance / taps)
          + 0.08 * cos(2 * .pi * distance / taps)
        let weight = 2 * cutoff * sinc(2 * cutoff * distance) * window
        accumulated += Double(samples[sourceIndex]) * weight
        weightSum += weight
      }
      // Normalizing by the kernel sum keeps unity gain at edges and for any
      // ratio, instead of trusting the ideal kernel to sum to 1 exactly.
      output[index] = weightSum > 0 ? Float(accumulated / weightSum) : 0
    }
    return output
  }

  private static func sinc(_ x: Double) -> Double {
    guard x != 0 else { return 1 }
    let scaled = .pi * x
    return sin(scaled) / scaled
  }
}

public struct WaveEncoder: Sendable {
  public init() {}

  public func encode(_ frames: [AudioFrame], outputSampleRate: Int) -> Data {
    let flattened = frames.flatMap(\.samples)
    let sourceRate = frames.first?.sampleRate ?? Double(outputSampleRate)
    let resampled = BandlimitedResampler.resample(
      flattened, from: sourceRate, to: Double(outputSampleRate))
    var pcm = Data(capacity: resampled.count * 2)
    for sample in resampled {
      var integer = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
      withUnsafeBytes(of: &integer) { pcm.append(contentsOf: $0) }
    }

    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    appendUInt32(UInt32(36 + pcm.count), to: &data)
    data.append("WAVEfmt ".data(using: .ascii)!)
    appendUInt32(16, to: &data)
    appendUInt16(1, to: &data)
    appendUInt16(1, to: &data)
    appendUInt32(UInt32(outputSampleRate), to: &data)
    appendUInt32(UInt32(outputSampleRate * 2), to: &data)
    appendUInt16(2, to: &data)
    appendUInt16(16, to: &data)
    data.append("data".data(using: .ascii)!)
    appendUInt32(UInt32(pcm.count), to: &data)
    data.append(pcm)
    return data
  }

  private func appendUInt16(_ value: UInt16, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }
}
