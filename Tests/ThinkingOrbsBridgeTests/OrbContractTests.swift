import Foundation
import MynaFlowCore
import Testing
import ThinkingOrbsKit

/// Facts about the vendored orb library that `ReactiveOrb` relies on.
///
/// The library is copied in verbatim and must never be hand-edited, so these
/// are the tests that speak up when a future re-sync changes something the
/// indicator quietly depends on. They are not testing the library's own
/// correctness — upstream has its own suite for that.
@Suite("ThinkingOrbsKit contract")
struct OrbContractTests {
  /// A spread of instants rather than one, since every value is a function of
  /// time and a single sample could sit in a lucky phase.
  private let instants: [Double] = stride(from: 0, through: 10, by: 0.05).map { $0 }

  @Test("The composing orb keeps its ghost sphere and sash cleanly apart by alpha")
  func layersStaySeparable() {
    let modulation = OrbLevelModulation()
    var brightestGhost = 0.0
    var faintestSash = 1.0

    for t in instants {
      for dot in orbFrame(state: .composing, size: .px64, t: t).dots {
        // `white` is the independent signal: the ghost sphere is drawn at a
        // constant 0.78 while every sash dot sits at 0.70 or below.
        if dot.white > 0.75 {
          brightestGhost = max(brightestGhost, dot.a)
        } else {
          faintestSash = min(faintestSash, dot.a)
        }
      }
    }

    #expect(brightestGhost < modulation.ghostAlphaThreshold)
    #expect(faintestSash >= modulation.ghostAlphaThreshold)
  }

  @Test(
    "Dot counts hold, so the measured cost of the pill still applies",
    arguments: [
      (OrbState.composing, 566), (.working, 516), (.solving, 138),
    ])
  func densityIsStable(state: OrbState, expected: Int) {
    // Measured at 44pt on a 120 Hz display: composing costs 12.5% of a core
    // at 60 Hz against 5.6% for the bars it replaced. A retune that changes
    // these counts invalidates that budget.
    let counts = Set(instants.map { orbFrame(state: state, size: .px64, t: $0).dots.count })
    #expect(counts == [expected])
  }

  @Test(
    "Every dot stays inside the orb's own bounds, even swelled to full level",
    arguments: [OrbState.composing, .working, .solving])
  func swellNeverClipsTheFrame(state: OrbState) {
    let modulation = OrbLevelModulation()
    let side = Double(OrbSize.px64.rawValue)
    let center = side / 2

    for t in instants {
      for dot in orbFrame(state: state, size: .px64, t: t).dots {
        let swelled = modulation.apply(
          x: dot.x, y: dot.y, r: dot.r, alpha: dot.a,
          centerX: center, centerY: center, level: 1)
        #expect(swelled.x - swelled.r >= 0)
        #expect(swelled.y - swelled.r >= 0)
        #expect(swelled.x + swelled.r <= side)
        #expect(swelled.y + swelled.r <= side)
      }
    }
  }

  @Test("The same instant draws the same frame, so the preset cache is safe")
  func framesAreDeterministic() {
    for t in [0.0, 1.25, 7.5] {
      let first = orbFrame(state: .composing, size: .px64, t: t).dots
      let second = orbFrame(state: .composing, size: .px64, t: t).dots
      #expect(first.count == second.count)
      for (a, b) in zip(first, second) {
        #expect(a.x == b.x)
        #expect(a.y == b.y)
        #expect(a.r == b.r)
        #expect(a.a == b.a)
        #expect(a.white == b.white)
      }
    }
  }

  @Test("Dots arrive sorted back to front, which is the order we draw them in")
  func dotsArriveZSorted() {
    for t in [0.0, 3.3, 8.8] {
      let dots = orbFrame(state: .composing, size: .px64, t: t).dots
      #expect(zip(dots, dots.dropFirst()).allSatisfy { $0.z <= $1.z })
    }
  }
}
