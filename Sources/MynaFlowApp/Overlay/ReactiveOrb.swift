import MynaFlowCore
import SwiftUI
import ThinkingOrbsKit

/// The indicator's orb: ThinkingOrbsKit's frame data, drawn in our own Canvas
/// so the live microphone can drive it.
///
/// The library is vendored verbatim and has no amplitude input, but
/// `orbFrame(state:size:t:)` is public and hands back dots whose position,
/// radius and alpha are all mutable — so we ask it for a frame and deform
/// that, rather than forking a package we want to keep re-syncing.
///
/// Two modes. Given a `level` and a `phase` the orb is voice-driven: it holds
/// completely still in silence, and expands, brightens and turns as you speak.
/// Given neither, it simply animates — that is the transcribing and polishing
/// case, where there is no microphone to follow.
struct ReactiveOrb: View {
  let state: OrbState
  var size: OrbSize = .px64
  /// The box the orb lives in. It is drawn smaller than this and grows into
  /// it, so the expansion has somewhere to go.
  var displaySize: CGFloat = 52
  /// Smoothed 0...1 envelope, or nil when this orb is not voice-driven.
  var level: Double?
  /// Orb-time from `OrbMotionClock`, which only advances while there is
  /// sound. Ignored unless `level` is also set.
  var phase: Double?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Stable start so re-evaluating the body cannot reschedule the ticks.
  private static let epoch = Date()
  /// The panel is transparent and always on top, so every frame costs a
  /// composite. Measured on a 120 Hz display: uncapped 19% of a core, 60 Hz
  /// 12.5%, 30 Hz 8.6% — against 5.6% for the five bars this replaced. Halve
  /// this if battery matters more than smoothness.
  private static let frameInterval: Double = 1.0 / 60
  /// The instant the library itself freezes on for Reduce Motion. Its own
  /// constant is internal, hence the literal.
  private static let reducedMotionT: Double = 0.6
  /// Size for the orbs that have no voice to follow, so transcribing and
  /// polishing sit at a steady middle rather than at either extreme.
  private static let restingScale: Double = 0.85

  private let modulation = OrbLevelModulation()

  var body: some View {
    Group {
      if let level {
        // Voice-driven: every redraw comes from the level or phase changing,
        // so a silent microphone is not merely still, it is free.
        canvas(t: (phase ?? 0) * speed, level: level)
      } else if reduceMotion {
        canvas(t: Self.reducedMotionT * speed, level: nil)
      } else {
        TimelineView(.periodic(from: Self.epoch, by: Self.frameInterval)) { timeline in
          canvas(t: timeline.date.timeIntervalSinceReferenceDate * speed, level: nil)
        }
      }
    }
    .frame(width: displaySize, height: displaySize)
    .accessibilityHidden(true)
  }

  private var speed: Double { resolvePreset(state, size).speed }

  private func canvas(t: Double, level: Double?) -> some View {
    Canvas(rendersAsynchronously: false) { context, _ in
      var context = context
      let side = Double(size.rawValue)
      let center = side / 2
      let zoom = Double(displaySize) / side
      if zoom != 1 { context.scaleBy(x: zoom, y: zoom) }

      // The whole orb expands and collapses with the voice, about its centre.
      let scale = level.map { modulation.orbScale(level: $0) } ?? Self.restingScale
      context.translateBy(x: center, y: center)
      context.scaleBy(x: scale, y: scale)
      context.translateBy(x: -center, y: -center)

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
          centerX: center, centerY: center, level: level ?? 0)
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
