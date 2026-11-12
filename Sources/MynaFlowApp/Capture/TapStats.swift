import MynaFlowCore
import os

/// Counters the system-audio IO block updates on Core Audio's queue, so a
/// stop can log whether the tap delivered anything. Levels and shapes only;
/// never audio content.
final class TapStats: Sendable {
  private struct Counts {
    var callbacks = 0
    var rejected = 0
    var samples = 0
    var peak: Float = 0
    var firstLayout = ""
  }

  private static let log = Logger(subsystem: "com.itssrb24.MynaFlow", category: "audio")
  private let counts = OSAllocatedUnfairLock(initialState: Counts())

  func noteCallback(layout: @autoclosure () -> [(UInt32, UInt32)]) {
    let isFirst = counts.withLock { state -> Bool in
      state.callbacks += 1
      return state.callbacks == 1
    }
    guard isFirst else { return }
    let layout = layout()
    let shape = layout.map { "\($0.0)ch/\($0.1)B" }.joined(separator: ",")
    counts.withLock { $0.firstLayout = shape }
    Self.log.debug("first tap callback: \(layout.count) buffer(s) [\(shape, privacy: .public)]")
  }

  func noteRejected() {
    counts.withLock { $0.rejected += 1 }
  }

  func noteFrame(_ frame: AudioFrame) {
    let peak = frame.samples.lazy.map(abs).max() ?? 0
    counts.withLock {
      $0.samples += frame.samples.count
      $0.peak = max($0.peak, peak)
    }
  }

  /// Callbacks so far and the loudest sample — enough to tell "nothing is
  /// arriving" and "only silence is arriving" apart from a working tap.
  var health: (callbacks: Int, peak: Float) {
    counts.withLock { ($0.callbacks, $0.peak) }
  }

  var summary: String {
    counts.withLock {
      "callbacks=\($0.callbacks) rejected=\($0.rejected) samples=\($0.samples) "
        + "peak=\(String(format: "%.4f", $0.peak)) layout=[\($0.firstLayout)]"
    }
  }
}
