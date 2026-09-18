import Foundation
import Testing

@testable import MynaFlowCore

@Suite("AudioLevelEnvelope")
struct AudioLevelEnvelopeTests {
  /// Drives the follower for `seconds` at a fixed step, returning the last output.
  private func drive(
    _ envelope: inout AudioLevelEnvelope, level: Double, seconds: Double, step: Double = 1.0 / 60
  ) -> Double {
    var elapsed = 0.0
    var out = envelope.output
    while elapsed < seconds {
      out = envelope.update(level: level, deltaTime: step)
      elapsed += step
    }
    return out
  }

  @Test("One attack time constant reaches about 63% of a step up")
  func attackTimeConstant() {
    var envelope = AudioLevelEnvelope()
    _ = drive(&envelope, level: 1, seconds: envelope.configuration.attack, step: 0.001)
    #expect(abs(envelope.state - 0.63) < 0.02)
    _ = drive(&envelope, level: 1, seconds: envelope.configuration.attack * 2, step: 0.001)
    #expect(envelope.state >= 0.95)
  }

  @Test("One release time constant decays to about 37%")
  func releaseTimeConstant() {
    var envelope = AudioLevelEnvelope()
    _ = drive(&envelope, level: 1, seconds: 1, step: 0.001)
    #expect(envelope.state > 0.99)
    _ = drive(&envelope, level: 0, seconds: envelope.configuration.release, step: 0.001)
    #expect(abs(envelope.state - 0.37) < 0.02)
  }

  @Test("Attack is faster than release, so the orb leaps up and glides down")
  func attackOutrunsRelease() {
    var rising = AudioLevelEnvelope()
    _ = drive(&rising, level: 1, seconds: 0.05, step: 0.001)
    let gained = rising.state

    var falling = AudioLevelEnvelope()
    _ = drive(&falling, level: 1, seconds: 1, step: 0.001)
    let before = falling.state
    _ = drive(&falling, level: 0, seconds: 0.05, step: 0.001)
    let lost = before - falling.state

    #expect(gained > lost)
  }

  @Test("The response is frame-rate independent")
  func frameRateIndependence() {
    var fine = AudioLevelEnvelope()
    for _ in 0..<10 { _ = fine.update(level: 1, deltaTime: 0.01) }
    var coarse = AudioLevelEnvelope()
    _ = coarse.update(level: 1, deltaTime: 0.1)
    #expect(abs(fine.state - coarse.state) < 1e-3)
  }

  @Test("Output stays inside the floor and 1, even across a long stall")
  func outputBounds() {
    var envelope = AudioLevelEnvelope()
    #expect(envelope.output == envelope.configuration.floor)
    _ = envelope.update(level: 1, deltaTime: 2)
    #expect(envelope.output <= 1)
    _ = drive(&envelope, level: 1, seconds: 3, step: 0.001)
    #expect(envelope.output <= 1)
    _ = drive(&envelope, level: 0, seconds: 5, step: 0.001)
    #expect(envelope.output >= envelope.configuration.floor)
  }

  @Test("A rising input never produces a falling output")
  func monotonic() {
    var envelope = AudioLevelEnvelope()
    var previous = envelope.output
    for step in 0...100 {
      let out = envelope.update(level: Double(step) / 100, deltaTime: 1.0 / 60)
      #expect(out >= previous - 1e-12)
      previous = out
    }
  }

  @Test("Non-finite input and non-positive time steps are ignored")
  func rejectsGarbage() {
    var envelope = AudioLevelEnvelope()
    _ = drive(&envelope, level: 0.5, seconds: 0.5, step: 0.001)
    let settled = envelope.state
    _ = envelope.update(level: .nan, deltaTime: 1.0 / 60)
    _ = envelope.update(level: .infinity, deltaTime: 1.0 / 60)
    _ = envelope.update(level: 1, deltaTime: 0)
    _ = envelope.update(level: 1, deltaTime: -1)
    #expect(envelope.state == settled)
    #expect(!envelope.output.isNaN)
  }

  @Test("Levels outside 0...1 are clamped rather than trusted")
  func clampsInput() {
    var envelope = AudioLevelEnvelope()
    _ = drive(&envelope, level: 9, seconds: 1, step: 0.001)
    #expect(envelope.state <= 1)
    _ = drive(&envelope, level: -4, seconds: 1, step: 0.001)
    #expect(envelope.state >= 0)
  }

  @Test("Reset returns to silence")
  func reset() {
    var envelope = AudioLevelEnvelope()
    _ = drive(&envelope, level: 1, seconds: 1, step: 0.001)
    envelope.reset()
    #expect(envelope.state == 0)
    #expect(envelope.output == envelope.configuration.floor)
  }

  @Test("It is a value: advancing a copy leaves the original alone")
  func valueSemantics() {
    var original = AudioLevelEnvelope()
    _ = drive(&original, level: 0.5, seconds: 0.2, step: 0.001)
    let snapshot = original.state
    var copy = original
    _ = drive(&copy, level: 1, seconds: 0.5, step: 0.001)
    #expect(original.state == snapshot)
    #expect(copy.state > snapshot)
  }

  @Test("The curve lifts quiet speech above a linear mapping")
  func expansionCurve() {
    var envelope = AudioLevelEnvelope()
    _ = drive(&envelope, level: 0.25, seconds: 2, step: 0.001)
    let floor = envelope.configuration.floor
    let linear = floor + (1 - floor) * 0.25
    #expect(envelope.output > linear)
  }
}
