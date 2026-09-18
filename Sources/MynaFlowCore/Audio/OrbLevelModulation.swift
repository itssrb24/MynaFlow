import Foundation

/// Deforms one orb dot by the live microphone level.
///
/// The orb library has no amplitude input — every state is a pure function of
/// size and time — so the reaction is applied here, to the frame the library
/// hands back, leaving its source untouched.
///
/// Two things happen at once. The whole orb expands and collapses with the
/// voice — that is the gesture you see across the room — and on top of it the
/// bright sash pushes a little further out and brightens, so the orb also has
/// texture up close rather than just changing size.
///
/// The `composing` orb draws two layers: a faint Fibonacci ghost sphere
/// (alpha `0.1 + 0.22 * depth`, so never above 0.32) and a bright multi-lane
/// sash (alpha `0.4 + 0.6 * depth`, so never below 0.40).
public struct OrbLevelModulation: Sendable {
  /// Size at silence, as a fraction of the space the orb is given. Small
  /// enough that the expansion reads as a real gesture.
  public var collapsedScale: Double
  /// Size at full level. Kept under 1 so the orb can never overrun its frame
  /// however loud the room gets — the containment proof is trivial.
  public var expandedScale: Double
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
    collapsedScale: Double = 0.52, expandedScale: Double = 0.90,
    sashRadialGain: Double = 0.08, sashRadiusGain: Double = 0.50,
    sashAlphaGain: Double = 0.50, ghostRadialGain: Double = 0,
    ghostAlphaThreshold: Double = 0.36
  ) {
    self.collapsedScale = collapsedScale
    self.expandedScale = expandedScale
    self.sashRadialGain = sashRadialGain
    self.sashRadiusGain = sashRadiusGain
    self.sashAlphaGain = sashAlphaGain
    self.ghostRadialGain = ghostRadialGain
    self.ghostAlphaThreshold = ghostAlphaThreshold
  }

  /// How big to draw the whole orb at this level: the expand-and-collapse.
  public func orbScale(level: Double) -> Double {
    let amount = level.isFinite ? min(1, max(0, level)) : 0
    return collapsedScale + (expandedScale - collapsedScale) * amount
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
