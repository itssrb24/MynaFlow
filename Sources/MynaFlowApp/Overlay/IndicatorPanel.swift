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
  private static let contentSize = NSSize(width: 280, height: 78)
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
    position()
    panel.orderFrontRegardless()
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

struct IndicatorView: View {
  let model: IndicatorModel

  var body: some View {
    content
      .frame(width: 280, height: 78)
      // The shade is allowed to spill into the window's transparent margin,
      // so it fades to nothing in free space. Clipped to the content frame it
      // would end mid-gradient and show as faint straight edges.
      .background(shade.padding(-28))
      .padding(30)
      .animation(.easeOut(duration: 0.15), value: model.display)
      .opacity(model.display == .hidden ? 0 : 1)
      .contentShape(Rectangle())
      .onTapGesture {
        if case .recording(.toggle) = model.display { model.onStopRequested() }
        if case .error = model.display, let action = model.onErrorAction { action() }
      }
  }

  /// There is no panel: the orb floats straight on the desktop. It also
  /// floats over white documents, though, where white dots and white text
  /// would simply disappear — so this sits underneath. An elliptical gradient
  /// with no hard edge reads as ambient shade rather than a box, which is the
  /// whole point, while still giving the content something to be legible
  /// against. Set `shadeStrength` to 0 for a completely bare orb.
  private var shade: some View {
    EllipticalGradient(
      gradient: Gradient(stops: [
        .init(color: .black.opacity(Self.shadeStrength), location: 0),
        .init(color: .black.opacity(Self.shadeStrength * 0.62), location: 0.45),
        .init(color: .black.opacity(Self.shadeStrength * 0.22), location: 0.75),
        .init(color: .clear, location: 1),
      ]),
      center: .center, startRadiusFraction: 0, endRadiusFraction: 0.52
    )
    .allowsHitTesting(false)
  }

  private static let shadeStrength: Double = 0.62

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
          Spacer(minLength: 0)
          Image(systemName: "stop.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(.orange)
        }
      }
      .padding(.horizontal, 18)
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
      .padding(.horizontal, 18)
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
      }
    case .error(let message):
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        Text(message)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(2)
      }
      .padding(.horizontal, 14)
    case .downloading(let what, let percent):
      HStack(spacing: 10) {
        ProgressView(value: Double(percent), total: 100)
          .frame(width: 90)
        Text("Downloading \(what) · \(percent)%")
          .font(.system(size: 12, weight: .medium))
      }
      .padding(.horizontal, 14)
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
      .padding(.horizontal, 18)
    }
  }

  private var elapsedLabel: String {
    String(format: "%d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60)
  }
}

