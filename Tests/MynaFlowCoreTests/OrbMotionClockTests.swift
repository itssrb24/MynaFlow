import Foundation
import Testing

@testable import MynaFlowCore

@Suite("OrbMotionClock")
struct OrbMotionClockTests {
  @Test("Silence holds the orb perfectly still")
  func silenceIsStill() {
    var clock = OrbMotionClock()
    // The envelope's idle floor still counts as silence.
    #expect(clock.rate(for: 0) == 0)
    #expect(clock.rate(for: 0.06) == 0)
    #expect(clock.rate(for: clock.configuration.silenceLevel) == 0)

    for _ in 0..<600 { _ = clock.advance(level: 0.06, deltaTime: 1.0 / 60) }
    #expect(clock.phase == 0, "ten seconds of silence must not move the orb at all")
  }

  @Test("Speech moves it, and louder moves it faster")
  func loudnessDrivesRate() {
    let clock = OrbMotionClock()
    let quiet = clock.rate(for: 0.3)
    let loud = clock.rate(for: 0.8)
    #expect(quiet > 0)
    #expect(loud > quiet)
    #expect(loud == clock.configuration.maxRate)
    #expect(clock.rate(for: 2) == clock.configuration.maxRate, "levels above 1 are clamped")
  }

  @Test("The rate ramps in smoothly rather than snapping on at the threshold")
  func rampIsContinuous() {
    let clock = OrbMotionClock()
    let justBelow = clock.rate(for: clock.configuration.silenceLevel - 0.001)
    let justAbove = clock.rate(for: clock.configuration.silenceLevel + 0.001)
    #expect(justBelow == 0)
    #expect(justAbove < 0.02, "no visible jolt as the first sound arrives")
  }

  @Test("Phase advances by rate times elapsed time, independently of frame rate")
  func phaseIsFrameRateIndependent() {
    var fine = OrbMotionClock()
    for _ in 0..<100 { _ = fine.advance(level: 1, deltaTime: 0.001) }
    var coarse = OrbMotionClock()
    _ = coarse.advance(level: 1, deltaTime: 0.1)
    #expect(abs(fine.phase - coarse.phase) < 1e-9)
    #expect(abs(coarse.phase - 0.1 * coarse.configuration.maxRate) < 1e-9)
  }

  @Test("Phase only ever moves forward, so the animation never jumps backwards")
  func phaseIsMonotonic() {
    var clock = OrbMotionClock()
    var previous = clock.phase
    for step in 0..<200 {
      let level = abs(sin(Double(step) / 9))
      let phase = clock.advance(level: level, deltaTime: 1.0 / 60)
      #expect(phase >= previous)
      previous = phase
    }
    #expect(clock.phase > 0)
  }

  @Test("Resuming after silence continues from where it stopped")
  func resumesWithoutJumping() {
    var clock = OrbMotionClock()
    for _ in 0..<60 { _ = clock.advance(level: 0.9, deltaTime: 1.0 / 60) }
    let beforePause = clock.phase
    for _ in 0..<300 { _ = clock.advance(level: 0, deltaTime: 1.0 / 60) }
    #expect(clock.phase == beforePause)
    _ = clock.advance(level: 0.9, deltaTime: 1.0 / 60)
    #expect(clock.phase > beforePause)
  }

  @Test("Garbage input cannot move or corrupt the phase")
  func rejectsGarbage() {
    var clock = OrbMotionClock()
    _ = clock.advance(level: 1, deltaTime: 0.5)
    let settled = clock.phase
    _ = clock.advance(level: .nan, deltaTime: 1.0 / 60)
    _ = clock.advance(level: 1, deltaTime: 0)
    _ = clock.advance(level: 1, deltaTime: -1)
    _ = clock.advance(level: 1, deltaTime: .infinity)
    #expect(clock.phase == settled)
    #expect(clock.phase.isFinite)
  }

  @Test("Reset returns to a standstill")
  func reset() {
    var clock = OrbMotionClock()
    _ = clock.advance(level: 1, deltaTime: 1)
    clock.reset()
    #expect(clock.phase == 0)
  }
}
