import AppKit
import ApplicationServices
import MynaFlowCore
import QuartzCore
import SwiftUI
import ThinkingOrbsKit

/// What the floating indicator is currently saying.
enum IndicatorDisplay: Equatable {
  case hidden
  case recording(mode: RecordingMode)
  case processing(engine: String)
  case success(words: Int, note: String?)
  /// The "dictated at the wrong moment" recovery — explicit, not a generic
  /// success. `reason` is appended when the caller knows why ("no text field
  /// was focused"); nil where the route is a catch-all.
  case clipboardFallback(reason: String?)
  case error(String)
  case downloading(what: String, percent: Int)
  case polishing(style: String)

  enum RecordingMode: Equatable {
    case hold
    case toggle
  }
}

@MainActor
@Observable
final class IndicatorModel {
  var display: IndicatorDisplay = .hidden
  /// Smoothed level the orb reads. Assigned only through `submitAudioLevel`.
  private(set) var orbLevel: Double = AudioLevelEnvelope().output
  /// Orb-time, which advances only while there is sound.
  private(set) var orbPhase: Double = 0
  var elapsedSeconds: Int = 0
  /// Clicking the pill during a toggle session stops it.
  var onStopRequested: () -> Void = {}
  /// Clicking an error pill that offers a fix (e.g. open System Settings).
  var onErrorAction: (() -> Void)?

  @ObservationIgnored private var envelope = AudioLevelEnvelope()
  @ObservationIgnored private var motion = OrbMotionClock()
  @ObservationIgnored private var lastLevelStamp: CFTimeInterval?

  /// The tap's raw RMS is far too jumpy to move geometry with, so the orb
  /// reads an envelope of it. The elapsed time is measured rather than
  /// assumed: the level poll is a sleep loop that drifts under load.
  ///
  /// Both properties are written only when they actually change. The poll
  /// keeps arriving 60 times a second through silence, and publishing an
  /// unchanged value would redraw the orb for nothing — the stillness has to
  /// reach all the way down, not just look still.
  func submitAudioLevel(_ level: Float) {
    let now = CACurrentMediaTime()
    let delta = lastLevelStamp.map { now - $0 } ?? 1.0 / 60
    lastLevelStamp = now

    let smoothed = envelope.update(level: Double(level), deltaTime: delta)
    if abs(smoothed - orbLevel) > 0.001 { orbLevel = smoothed }
    let advanced = motion.advance(level: smoothed, deltaTime: delta)
    if advanced != orbPhase { orbPhase = advanced }
  }

  func resetAudioLevel() {
    envelope.reset()
    motion.reset()
    lastLevelStamp = nil
    orbLevel = envelope.output
    orbPhase = 0
  }
}

/// An NSPanel that goes exactly where it is put. AppKit constrains ordinary
/// windows against screen edges; the indicator's transparent shadow margin
/// makes that constraint reposition the visible pill, so it is disabled.
private final class UnconstrainedPanel: NSPanel {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// Floating indicator anchored bottom-center of the active screen. Never
/// steals focus, joins all Spaces, floats over full-screen apps.
enum IndicatorPlacement: String, CaseIterable {
  case bottomCenter, topCenter

  var displayName: String {
    switch self {
    case .bottomCenter: "Bottom center"
    case .topCenter: "Top center"
    }
  }
}

@MainActor
final class IndicatorPanelController {
  private static let contentSize = NSSize(width: 340, height: 78)
  private static let shadowMargin: CGFloat = 30
  private static let edgeInset: CGFloat = 24

  var placement: IndicatorPlacement = .bottomCenter {
    didSet { position() }
  }

  private let panel: NSPanel
  private var hideTask: Task<Void, Never>?
  private nonisolated(unsafe) var screenObserver: (any NSObjectProtocol)?

  init(model: IndicatorModel) {
    let windowSize = NSSize(
      width: Self.contentSize.width + Self.shadowMargin * 2,
      height: Self.contentSize.height + Self.shadowMargin * 2)
    panel = UnconstrainedPanel(
      contentRect: NSRect(origin: .zero, size: windowSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // SwiftUI draws the pill's shadow. The NSWindow shadow must stay OFF:
    // recomputing a transparent window's shadow on frequently-redrawn content
    // (a live waveform) is expensive.
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
    position()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.position() }
    }
  }

  deinit {
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
  }

  func show() {
    hideTask?.cancel()
    hideTask = nil
    let started = CACurrentMediaTime()
    position()
    panel.orderFrontRegardless()
    let elapsed = CACurrentMediaTime() - started
    // The budget from the hotkey edge to a visible pill is 100 ms for the
    // whole path; if placing the window alone eats a fifth of it, say so.
    if elapsed > 0.02 {
      DiagnosticsLog.shared.write(
        "warn", "app", "indicator placement took \(Int(elapsed * 1000)) ms")
    }
  }

  /// Deferred orderOut so SwiftUI can animate the fade on its next pass.
  func hide() {
    hideTask?.cancel()
    hideTask = Task { [weak panel] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      panel?.orderOut(nil)
    }
  }

  /// The screen the user is looking at: the one holding the frontmost app's
  /// focused window, else the one under the mouse, else main. `NSScreen.main`
  /// alone follows *our* key window, which a menu bar app rarely has.
  private func targetScreen() -> NSScreen? {
    // With one display there is nothing to choose, and the AX round-trip
    // below is a synchronous call into another process — on the hotkey path,
    // where a busy app (Chrome, an Electron editor) can stall the pill for
    // long enough to feel like lag. Skip it entirely.
    guard NSScreen.screens.count > 1 else { return NSScreen.screens.first }
    if let application = NSWorkspace.shared.frontmostApplication,
      let rect = Self.focusedWindowFrame(of: application)
    {
      let center = NSPoint(x: rect.midX, y: rect.midY)
      if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
        return screen
      }
    }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
      ?? NSScreen.main ?? NSScreen.screens.first
  }

  /// Cocoa-space frame of the frontmost app's focused window via AX.
  private static func focusedWindowFrame(of application: NSRunningApplication) -> NSRect? {
    let element = AXUIElementCreateApplication(application.processIdentifier)
    // Bound the wait: placing the pill on the right screen is a nicety, and
    // never worth blocking its appearance for.
    AXUIElementSetMessagingTimeout(element, 0.05)
    var windowRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
      let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID()
    else { return nil }
    let window = windowRef as! AXUIElement
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
      let positionRef, let sizeRef
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
      AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
      let primary = NSScreen.screens.first
    else { return nil }
    // AX is top-left origin; Cocoa is bottom-left against the primary screen.
    let cocoaY = primary.frame.maxY - (position.y + size.height)
    return NSRect(x: position.x, y: cocoaY, width: size.width, height: size.height)
  }

  private func position() {
    guard let screen = targetScreen() else { return }
    let visible = screen.visibleFrame
    let y: CGFloat
    switch placement {
    case .bottomCenter:
      y = visible.minY + Self.edgeInset - Self.shadowMargin
    case .topCenter:
      y = visible.maxY - Self.edgeInset - Self.contentSize.height - Self.shadowMargin
    }
    panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: y))
  }
}

// MARK: - View

/// `NSVisualEffectView` in behind-window mode: the same blur AppKit gives its
/// own HUDs. Pinned to the dark appearance regardless of the system theme,
/// because the content drawn on it is always white.
private struct GlassBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.isEmphasized = false
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct IndicatorView: View {
  let model: IndicatorModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    content
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(minHeight: 62)
      .background(glass)
      // The pill is only as wide as what it is saying, and morphs when that
      // changes — so it carries the same low-bounce spring as the shapes it
      // borrows from rather than snapping between widths.
      .animation(morph, value: model.display)
      // Appearing should feel like the key press itself, so it pops in on a
      // short spring rather than fading over 150 ms, which reads as lag.
      .scaleEffect(isVisible ? 1 : 0.92)
      .opacity(isVisible ? 1 : 0)
      .animation(appear, value: isVisible)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture {
        if case .recording(.toggle) = model.display { model.onStopRequested() }
        if case .error = model.display, let action = model.onErrorAction { action() }
      }
  }

  private var isVisible: Bool { model.display != .hidden }

  /// Reduced motion keeps the cross-fade, which aids comprehension, and drops
  /// the movement.
  private var appear: Animation {
    reduceMotion
      ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.76)
  }

  private var morph: Animation {
    reduceMotion
      ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.9)
  }

  /// Apple's glass, not a coloured pane: a frosted sheet that takes its
  /// colour from whatever is behind it rather than staining it.
  ///
  /// The body is a near-neutral graphite — warm enough never to be flat black,
  /// but carrying no hue of its own — so the wallpaper, the document, the
  /// window underneath all read through. State lives in a whisper of tint and
  /// in the coloured glyph beside the text, not in a wash over the pane.
  ///
  /// The rim is the signature. A hairline that catches light along the top
  /// edge and fades around the curve, over a sheen just inside it, is what
  /// separates a sheet of glass from a rounded rectangle with a blur.
  private var glass: some View {
    let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    let accent = stateTint
    let tint = LinearGradient(
      colors: [
        accent.color.opacity(accent.opacity),
        accent.color.opacity(accent.opacity * 0.40),
        accent.color.opacity(accent.opacity * 0.65),
      ],
      startPoint: .topLeading, endPoint: .bottomTrailing)
    let rim = LinearGradient(
      colors: [
        .white.opacity(Self.rimStrength),
        .white.opacity(Self.rimStrength * 0.30),
        .white.opacity(Self.rimStrength * 0.15),
      ],
      startPoint: .top, endPoint: .bottom)
    let sheen = LinearGradient(
      colors: [.white.opacity(0.22), .white.opacity(0.045), .clear],
      startPoint: .top, endPoint: .center)

    let blurred = shape.fill(Color.clear)
      .background(GlassBackdrop().clipShape(shape))
    let veiled = blurred.overlay(shape.fill(Self.graphite.opacity(Self.veilStrength)))
    let tinted = veiled.overlay(shape.fill(tint))
    let lit = tinted.overlay(shape.fill(sheen))
    return lit
      .overlay(shape.strokeBorder(rim, lineWidth: 1))
      .shadow(color: Self.graphite.opacity(0.40), radius: 20, y: 8)
      .allowsHitTesting(false)
  }

  /// A warm near-neutral. Never `.black`: a pane held back with pure black
  /// goes flat and grey, and stops reading as glass at all.
  private static let graphite = Color(red: 0.115, green: 0.108, blue: 0.098)
  /// How much the sheet holds back what is behind it. The floor that keeps
  /// white content legible over a white page.
  private static let veilStrength: Double = 0.22
  private static let rimStrength: Double = 0.48

  /// A whisper of the state's colour — enough that the sheet warms while you
  /// speak, far too little to stain it. The state itself is carried by the
  /// glyph beside the text.
  private var stateTint: (color: Color, opacity: Double) {
    switch model.display {
    case .recording(.hold):
      return (Theme.Colors.accent, 0.05 + 0.09 * model.orbLevel)
    case .recording(.toggle):
      return (.orange, 0.07 + 0.08 * model.orbLevel)
    case .processing, .downloading:
      return (Theme.Colors.accent, 0.05)
    case .polishing:
      return (Theme.Colors.accent, 0.07)
    case .error:
      return (.red, 0.10)
    case .success, .clipboardFallback:
      return (.green, 0.07)
    case .hidden:
      return (Theme.Colors.accent, 0)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.display {
    case .hidden:
      EmptyView()
    case .recording(let mode):
      HStack(spacing: 10) {
        ReactiveOrb(
          state: .composing, displaySize: 62, level: model.orbLevel, phase: model.orbPhase)
        VStack(alignment: .leading, spacing: 2) {
          Text(mode == .hold ? "Listening" : "Listening — toggle")
            .font(.system(size: 13, weight: .semibold))
          Text(elapsedLabel)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        if mode == .toggle {
          Image(systemName: "stop.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(.orange)
            .padding(.leading, 2)
        }
      }
    case .processing(let engine):
      HStack(spacing: 10) {
        ReactiveOrb(state: .working, displaySize: 50)
        VStack(alignment: .leading, spacing: 2) {
          Text("Transcribing")
            .font(.system(size: 13, weight: .semibold))
          Text(engine)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    case .success(let words, let note):
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        VStack(alignment: .leading, spacing: 1) {
          Text(words == 0 ? "Done" : words == 1 ? "Inserted 1 word" : "Inserted \(words) words")
            .font(.system(size: 13, weight: .medium))
          if let note {
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
      }
    case .clipboardFallback(let reason):
      HStack(spacing: 8) {
        Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.yellow)
        Text(
          reason.map { "Saved to history and copied to clipboard — \($0)" }
            ?? "Saved to history and copied to clipboard")
          .font(.system(size: 12, weight: .medium))
          .frame(maxWidth: 230, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .error(let message):
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        Text(message)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(2)
          .frame(maxWidth: 240, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .downloading(let what, let percent):
      HStack(spacing: 10) {
        ProgressView(value: Double(percent), total: 100)
          .frame(width: 90)
        Text("Downloading \(what) · \(percent)%")
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
      }
    case .polishing(let style):
      HStack(spacing: 10) {
        ReactiveOrb(state: .solving, displaySize: 50)
        VStack(alignment: .leading, spacing: 2) {
          Text("Polishing")
            .font(.system(size: 13, weight: .semibold))
          Text(style)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private var elapsedLabel: String {
    String(format: "%d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60)
  }
}

