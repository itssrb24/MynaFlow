import Foundation

/// The orb's own sense of time: it advances only while someone is speaking.
///
/// The animation cannot read the wall clock, because then it would keep
/// turning through silence. Instead the phase accumulates at a rate set by the
/// microphone, so a silent room leaves the orb completely still and a loud
/// voice drives it faster than real time. Because the phase only ever moves
/// forward, speech resuming after a pause picks up exactly where it stopped
/// rather than jumping to wherever absolute time had got to.
public struct OrbMotionClock: Sendable {
  public struct Configuration: Sendable {
    /// At or below this level nothing moves. Sits above the envelope's idle
    /// floor so a quiet room is genuinely still, not slowly creeping.
    public var silenceLevel: Double
    /// The level at which the orb reaches full speed.
    public var fullLevel: Double
    /// Seconds of orb time per real second at full level. Above 1 so loud
    /// speech visibly drives it rather than merely resuming normal motion.
    public var maxRate: Double

    public init(silenceLevel: Double = 0.12, fullLevel: Double = 0.75, maxRate: Double = 1.7) {
      self.silenceLevel = silenceLevel
      self.fullLevel = fullLevel
      self.maxRate = maxRate
    }
  }

  public let configuration: Configuration
  public private(set) var phase: Double = 0

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// Orb-seconds per real second at this level. Eased at both ends so the
  /// first sound fades the motion in instead of snapping it on.
  public func rate(for level: Double) -> Double {
    guard level.isFinite else { return 0 }
    let span = configuration.fullLevel - configuration.silenceLevel
    guard span > 0 else { return level > configuration.silenceLevel ? configuration.maxRate : 0 }
    let normalized = (min(1, max(0, level)) - configuration.silenceLevel) / span
    guard normalized > 0 else { return 0 }
    let clamped = min(1, normalized)
    // Smoothstep: zero slope at both ends.
    return configuration.maxRate * clamped * clamped * (3 - 2 * clamped)
  }

  @discardableResult
  public mutating func advance(level: Double, deltaTime: Double) -> Double {
    guard deltaTime.isFinite, deltaTime > 0 else { return phase }
    phase += rate(for: level) * deltaTime
    return phase
  }

  public mutating func reset() {
    phase = 0
  }
}
