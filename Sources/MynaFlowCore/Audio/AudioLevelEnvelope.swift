import Foundation

/// Turns the capture tap's raw per-buffer RMS into something worth animating.
///
/// The tap delivers `sqrt(mean(square)) * 8` with no smoothing at all, which
/// jitters hard from buffer to buffer — fine for five bars that only change
/// height, far too jumpy to move geometry with. This is a one-pole follower
/// with a fast attack and a slow release, so the orb leaps on a syllable and
/// glides back down between words instead of strobing.
public struct AudioLevelEnvelope: Sendable {
  public struct Configuration: Sendable {
    /// Seconds to cover ~63% of a rise. Short: a syllable onset has to land
    /// within a poll or two or the orb visibly lags the voice.
    public var attack: Double
    /// Seconds to cover ~63% of a fall. Longer, so gaps between words read as
    /// one continuous gesture rather than a flicker.
    public var release: Double
    /// Output never drops below this, so a silent microphone still looks
    /// armed rather than dead.
    public var floor: Double
    /// Exponent below 1 expands quiet speech, which RMS bunches near zero.
    public var curve: Double

    public init(
      attack: Double = 0.035, release: Double = 0.28, floor: Double = 0.06,
      curve: Double = 0.75
    ) {
      self.attack = attack
      self.release = release
      self.floor = floor
      self.curve = curve
    }
  }

  public let configuration: Configuration
  /// The follower itself, 0...1, with no floor or curve applied. Kept
  /// separate so the dynamics stay testable independently of presentation.
  public private(set) var state: Double = 0

  /// What the animation reads: floor-lifted and curve-shaped.
  public var output: Double {
    configuration.floor + (1 - configuration.floor) * pow(state, configuration.curve)
  }

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// Advances the follower. `deltaTime` is measured rather than assumed by the
  /// caller, so a stalled poll loop cannot distort the response.
  @discardableResult
  public mutating func update(level: Double, deltaTime: Double) -> Double {
    guard level.isFinite, deltaTime.isFinite, deltaTime > 0 else { return output }
    let target = min(1, max(0, level))
    let tau = target > state ? configuration.attack : configuration.release
    // 1 - e^(-dt/tau) rather than a fixed step, so ten 10 ms updates land in
    // the same place as one 100 ms update.
    let coefficient = tau <= 0 ? 1 : 1 - exp(-deltaTime / tau)
    state = min(1, max(0, state + (target - state) * coefficient))
    return output
  }

  public mutating func reset() {
    state = 0
  }
}
