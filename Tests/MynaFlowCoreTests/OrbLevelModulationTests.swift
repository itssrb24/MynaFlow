import Foundation
import Testing

@testable import MynaFlowCore

@Suite("OrbLevelModulation")
struct OrbLevelModulationTests {
  private let modulation = OrbLevelModulation()
  private let center = 32.0

  private func apply(x: Double, y: Double, r: Double, alpha: Double, level: Double)
    -> OrbLevelModulation.Point
  {
    modulation.apply(
      x: x, y: y, r: r, alpha: alpha, centerX: center, centerY: center, level: level)
  }

  @Test("Silence is the identity, so a quiet mic renders the library's own orb")
  func silenceIsIdentity() {
    for alpha in [0.1, 0.32, 0.4, 0.9] {
      let point = apply(x: 40, y: 28, r: 0.7, alpha: alpha, level: 0)
      #expect(point.x == 40)
      #expect(point.y == 28)
      #expect(point.r == 0.7)
      #expect(point.alpha == alpha)
    }
  }

  @Test("The faint ghost sphere and the bright sash are told apart by alpha")
  func layerSplit() {
    // composing draws the ghost at alpha 0.1...0.32 and the sash at 0.4...1.0.
    let ghost = apply(x: 40, y: 32, r: 0.5, alpha: 0.32, level: 1)
    let sash = apply(x: 40, y: 32, r: 0.5, alpha: 0.40, level: 1)
    #expect(ghost.r == 0.5, "the ghost keeps its radius")
    #expect(ghost.alpha == 0.32, "the ghost keeps its alpha")
    #expect(sash.r > 0.5)
    #expect(sash.alpha > 0.40)
    // The ghost still drifts, just far less than the sash.
    #expect(ghost.x - center < sash.x - center)
    #expect(ghost.x > 40)
  }

  @Test("Displacement is purely radial")
  func radialDisplacement() {
    let point = apply(x: 44, y: 20, r: 0.5, alpha: 0.8, level: 1)
    let inputAngle = atan2(20 - center, 44 - center)
    let outputAngle = atan2(point.y - center, point.x - center)
    #expect(abs(inputAngle - outputAngle) < 1e-12)

    let inputRadius = hypot(44 - center, 20 - center)
    let outputRadius = hypot(point.x - center, point.y - center)
    let expected = inputRadius * (1 + modulation.sashRadialGain)
    #expect(abs(outputRadius - expected) < 1e-12)
  }

  @Test("A dot at the centre never moves")
  func centerIsFixed() {
    let point = apply(x: center, y: center, r: 0.5, alpha: 0.9, level: 1)
    #expect(point.x == center)
    #expect(point.y == center)
  }

  @Test("Radius and alpha rise with level and never exceed their limits")
  func monotonicAndBounded() {
    var lastRadius = 0.0
    var lastAlpha = 0.0
    for step in 0...20 {
      let level = Double(step) / 20
      let point = apply(x: 40, y: 32, r: 0.6, alpha: 0.95, level: level)
      #expect(point.r >= lastRadius)
      #expect(point.alpha >= lastAlpha)
      #expect(point.alpha <= 1)
      lastRadius = point.r
      lastAlpha = point.alpha
    }
  }

  @Test("Levels outside 0...1, and NaN, are clamped")
  func clampsLevel() {
    let loud = apply(x: 40, y: 32, r: 0.6, alpha: 0.8, level: 12)
    let full = apply(x: 40, y: 32, r: 0.6, alpha: 0.8, level: 1)
    #expect(loud.x == full.x)
    #expect(loud.r == full.r)

    let negative = apply(x: 40, y: 32, r: 0.6, alpha: 0.8, level: -3)
    let notANumber = apply(x: 40, y: 32, r: 0.6, alpha: 0.8, level: .nan)
    #expect(negative.x == 40)
    #expect(notANumber.x == 40)
    #expect(notANumber.r == 0.6)
  }

  @Test("At full level the swell still fits inside the orb's own bounds")
  func staysInsideTheFrame() {
    // composing@px64: the sash rides a sphere of radius size/2 * 0.78 and the
    // widest dot is ~1.3pt. If a gain is raised too far the orb clips its frame.
    let size = 64.0
    let sphereRadius = size / 2 * 0.78
    let widestDot = 1.3
    let farthest = sphereRadius * (1 + modulation.sashRadialGain) + widestDot
      * (1 + modulation.sashRadiusGain)
    #expect(farthest <= size / 2)
  }
}
