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
  var display: IndicatorDisplay = .hidden {
    // The action belongs to one error pill. Clearing it for any other
    // display means a later, unrelated error cannot open the wrong System
    // Settings pane — which it did, because nothing ever reset it.
    didSet { if case .error = display {} else { onErrorAction = nil } }
  }
  /// Smoothed level the orb reads. Assigned only through `submitAudioLevel`.
  private(set) var orbLevel: Double = AudioLevelEnvelope().output
  /// Orb-time, which advances only while there is sound.
  private(set) var orbPhase: Double = 0
  var elapsedSeconds: Int = 0
  /// Replaces "Listening — toggle" while recording, e.g. "Meeting notes".
  var recordingLabel: String?
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
  private static let contentSize = NSSize(width: 320, height: 44)
  private static let shadowMargin: CGFloat = 20
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
    // Electron and Java accessibility servers, and half-torn-down windows,
    // hand back other types here. This runs on every hotkey press, so a force
    // cast would be a crash on someone else's Mac.
    guard CFGetTypeID(positionRef) == AXValueGetTypeID(),
      CFGetTypeID(sizeRef) == AXValueGetTypeID()
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

/// `NSVisualEffectView` in behind-window mode, pinned dark. Under the pill's
/// near-black fill it only keeps the edges from looking pasted on.
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

/// The floating indicator: a slim black capsule that says as little as the
/// moment needs — the orb and a timer while you talk, one word while it
/// works, and a card only when a message needs two lines.
struct IndicatorView: View {
  let model: IndicatorModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    content
      .padding(.leading, isCard ? 12 : 10)
      .padding(.trailing, 12)
      .padding(.vertical, isCard ? 9 : 0)
      .frame(minHeight: Self.height)
      .background(surface)
      .environment(\.colorScheme, .dark)
      // Only as wide as what it says; morphs rather than snapping.
      .animation(morph, value: model.display)
      // Rises a few points out of the screen edge as it pops in.
      .scaleEffect(isVisible ? 1 : 0.9)
      .offset(y: isVisible || reduceMotion ? 0 : 6)
      .opacity(isVisible ? 1 : 0)
      .animation(appear, value: isVisible)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture {
        if case .recording(.toggle) = model.display { model.onStopRequested() }
        if case .error = model.display, let action = model.onErrorAction { action() }
      }
  }

  static let height: CGFloat = 34

  private var isVisible: Bool { model.display != .hidden }

  /// Errors and a clipboard notice with a reason can need two lines; a
  /// capsule can't hold them, so they become a rounded card.
  private var isCard: Bool {
    switch model.display {
    case .error(let message): message.count > 34
    case .clipboardFallback(let reason): reason != nil
    default: false
    }
  }

  private var appear: Animation {
    reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.8)
  }

  private var morph: Animation {
    reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.9)
  }

  /// Near-black, not glass: a solid fill reads as one crisp object over any
  /// wallpaper. A hairline rim and a faint top highlight give it an edge.
  private var surface: some View {
    let shape = RoundedRectangle(cornerRadius: isCard ? 14 : Self.height / 2, style: .continuous)
    return shape.fill(Color(white: 0.06).opacity(0.94))
      .background(GlassBackdrop().clipShape(shape))
      .overlay(
        shape.strokeBorder(
          LinearGradient(
            colors: [.white.opacity(0.16), .white.opacity(0.07)],
            startPoint: .top, endPoint: .bottom),
          lineWidth: 0.75)
      )
      .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
      .allowsHitTesting(false)
  }

  @ViewBuilder
  private var content: some View {
    switch model.display {
    case .hidden:
      EmptyView()
    case .recording(let mode):
      if let label = model.recordingLabel {
        HStack(spacing: 8) {
          RecordingDot()
          Text(label == "Meeting notes" ? "Notes" : label).pillLabel()
          Text(elapsedLabel).pillTimer()
          StopButton()
        }
        .accessibilityElement(children: .combine)
      } else {
        HStack(spacing: 8) {
          ReactiveOrb(
            state: .composing, size: .px20, displaySize: 26,
            level: model.orbLevel, phase: model.orbPhase)
          Text(elapsedLabel).pillTimer()
          if mode == .toggle { StopButton() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening, \(elapsedLabel)")
      }
    case .processing:
      HStack(spacing: 8) {
        ReactiveOrb(state: .working, size: .px20, displaySize: 26)
        Text("Transcribing").pillLabel()
      }
    case .polishing(let style):
      HStack(spacing: 8) {
        ReactiveOrb(state: .solving, size: .px20, displaySize: 26)
        Text(style.hasPrefix("retrying") ? "Retrying" : "Polishing").pillLabel()
      }
    case .success(let words, let note):
      HStack(spacing: 7) {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(Theme.Colors.success)
        Text(words == 0 ? "Done" : words == 1 ? "1 word" : "\(words) words").pillLabel()
        if let note { Text(note).pillTimer().lineLimit(1) }
      }
    case .clipboardFallback(let reason):
      HStack(alignment: reason == nil ? .center : .top, spacing: 8) {
        Image(systemName: "doc.on.clipboard")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.Colors.warning)
          .padding(.top, reason == nil ? 0 : 1)
        VStack(alignment: .leading, spacing: 2) {
          Text("Copied to clipboard").pillLabel()
          if let reason {
            Text(reason.prefix(1).uppercased() + reason.dropFirst())
              .font(.system(size: 11))
              .foregroundStyle(.white.opacity(0.6))
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: 260, alignment: .leading)
      }
    case .error(let message):
      HStack(alignment: isCard ? .top : .center, spacing: 8) {
        ErrorBadge().padding(.top, isCard ? 1 : 0)
        Text(message)
          .pillLabel()
          .lineLimit(2)
          .frame(maxWidth: 260, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .downloading(let what, let percent):
      HStack(spacing: 8) {
        ProgressRing(fraction: Double(percent) / 100)
        Text("\(what) \(percent)%").pillLabel().lineLimit(1)
      }
    }
  }

  private var elapsedLabel: String {
    String(format: "%d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60)
  }
}
