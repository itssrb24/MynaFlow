import MynaFlowCore
import SwiftUI
import ThinkingOrbsKit

/// The indicator's orb: ThinkingOrbsKit's frame data, drawn in our own Canvas
/// so the live microphone can deform it.
///
/// The library is vendored verbatim and has no amplitude input of its own, but
/// `orbFrame(state:size:t:)` is public and hands back dots whose position,
/// radius and alpha are all mutable. So we ask it for a frame and swell that,
/// rather than forking a package we want to keep re-syncing.
struct ReactiveOrb: View {
  let state: OrbState
  var size: OrbSize = .px64
  var displaySize: CGFloat = 44
  /// Smoothed 0...1 envelope. At 0 this renders the stock orb exactly.
  var level: Double = 0
  /// Non-nil drives the animation from an external clock instead of
  /// TimelineView. Unused today: TimelineView was measured ticking at full
  /// refresh rate inside the indicator's non-key panel.
  var clock: Double?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Stable start so re-evaluating the body cannot reschedule the ticks.
  private static let epoch = Date()
  /// The panel is transparent and always on top, so every frame costs a
  /// composite. Measured on a 120 Hz display at 44pt: uncapped 19% of a core,
  /// 60 Hz 12.5%, 30 Hz 8.6% — against 5.6% for the five bars this replaces.
  /// 60 Hz is the smooth/cheap balance; halve it here if battery matters more.
  private static let frameInterval: Double = 1.0 / 60
  /// The instant the library itself freezes on for Reduce Motion. Its own
  /// constant is internal, hence the literal.
  private static let reducedMotionT: Double = 0.6

  private let modulation = OrbLevelModulation()

  var body: some View {
    let speed = resolvePreset(state, size).speed
    Group {
      if let clock {
        canvas(t: clock * speed)
      } else if reduceMotion {
        // Still reacts to the microphone — the level is information, not
        // decoration — but nothing moves on its own.
        canvas(t: Self.reducedMotionT * speed)
      } else {
        TimelineView(.periodic(from: Self.epoch, by: Self.frameInterval)) { timeline in
          canvas(t: timeline.date.timeIntervalSinceReferenceDate * speed)
        }
      }
    }
    .frame(width: displaySize, height: displaySize)
    .accessibilityHidden(true)
  }

  private func canvas(t: Double) -> some View {
    Canvas(rendersAsynchronously: false) { context, _ in
      var context = context
      let side = Double(size.rawValue)
      let zoom = Double(displaySize) / side
      if zoom != 1 { context.scaleBy(x: zoom, y: zoom) }
      let center = side / 2
      let frame = orbFrame(state: state, size: size, t: t)

      // Lines first so nodes sit on their edges, matching the library. The
      // states we use emit none today; kept so any future state still draws.
      for line in frame.lines {
        var path = Path()
        path.move(to: CGPoint(x: line.x1, y: line.y1))
        path.addLine(to: CGPoint(x: line.x2, y: line.y2))
        context.stroke(path, with: .color(ink(line.white, line.a)), lineWidth: line.w)
      }
      // Already sorted far to near by the library; we never touch z, so that
      // draw order stays correct.
      for dot in frame.dots {
        let swelled = modulation.apply(
          x: dot.x, y: dot.y, r: dot.r, alpha: dot.a,
          centerX: center, centerY: center, level: level)
        let rect = CGRect(
          x: swelled.x - swelled.r, y: swelled.y - swelled.r,
          width: swelled.r * 2, height: swelled.r * 2)
        context.fill(Path(ellipseIn: rect), with: .color(ink(dot.white, swelled.alpha)))
      }
    }
  }

  /// The library's own ink, dark branch only: the pill chrome is always dark.
  /// Quantised to 8 bits exactly as upstream does, so the greys match.
  private func ink(_ white: Double, _ alpha: Double) -> Color {
    let clamped = min(1, max(0, white))
    let grey = ((1 - clamped) * 255).rounded(.toNearestOrAwayFromZero) / 255
    return Color(.sRGB, white: grey, opacity: alpha)
  }
}
