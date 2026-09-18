import Foundation

/// Deforms one orb dot by the live microphone level.
///
/// The orb library has no amplitude input — every state is a pure function of
/// size and time — so the reaction is applied here, to the frame the library
/// hands back, leaving its source untouched.
///
/// The `composing` orb draws two layers: a faint Fibonacci ghost sphere
/// (alpha `0.1 + 0.22 * depth`, so never above 0.32) and a bright multi-lane
/// sash (alpha `0.4 + 0.6 * depth`, so never below 0.40). Swelling the sash
/// while leaving the ghost nearly still is what makes the orb read as
/// *reacting*; swelling everything equally is indistinguishable from scaling
/// the whole view, which is both cheaper and duller.
public struct OrbLevelModulation: Sendable {
  /// How far the sash pushes out from the centre at full level.
  public var sashRadialGain: Double
  /// How much fatter each sash dot gets at full level.
  public var sashRadiusGain: Double
  /// How much brighter the sash gets — the strongest cue at this size.
  public var sashAlphaGain: Double
  /// The ghost drifts a little so the orb breathes as a whole.
  public var ghostRadialGain: Double
  /// Alpha below this is the ghost sphere, above it is the sash. The two
  /// layers sit either side of a wide gap (0.32 against 0.40); a bridge test
  /// fails loudly if an upstream retune ever closes it.
  public var ghostAlphaThreshold: Double

  public struct Point: Sendable {
    public var x: Double
    public var y: Double
    public var r: Double
    public var alpha: Double
  }

  public init(
    sashRadialGain: Double = 0.16, sashRadiusGain: Double = 0.45,
    sashAlphaGain: Double = 0.35, ghostRadialGain: Double = 0.04,
    ghostAlphaThreshold: Double = 0.36
  ) {
    self.sashRadialGain = sashRadialGain
    self.sashRadiusGain = sashRadiusGain
    self.sashAlphaGain = sashAlphaGain
    self.ghostRadialGain = ghostRadialGain
    self.ghostAlphaThreshold = ghostAlphaThreshold
  }

  /// `level` 0 returns the dot exactly as the library drew it.
  public func apply(
    x: Double, y: Double, r: Double, alpha: Double,
    centerX: Double, centerY: Double, level: Double
  ) -> Point {
    let amount = level.isFinite ? min(1, max(0, level)) : 0
    let isGhost = alpha < ghostAlphaThreshold
    let scale = 1 + (isGhost ? ghostRadialGain : sashRadialGain) * amount
    return Point(
      x: centerX + (x - centerX) * scale,
      y: centerY + (y - centerY) * scale,
      // The ghost keeps its size and brightness: it is the fixed reference
      // the sash is seen to swell against.
      r: isGhost ? r : r * (1 + sashRadiusGain * amount),
      alpha: isGhost ? alpha : min(1, alpha * (1 + sashAlphaGain * amount)))
  }
}
