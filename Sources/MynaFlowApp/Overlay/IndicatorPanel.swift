import AppKit
import SwiftUI

/// What the floating indicator is currently saying.
enum IndicatorDisplay: Equatable {
  case hidden
  case recording(mode: RecordingMode)
  case processing(engine: String)
  case success(words: Int, note: String?)
  /// The "dictated at the wrong moment" recovery — explicit, not a generic
  /// success.
  case clipboardFallback
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
  var audioLevel: Float = 0
  var elapsedSeconds: Int = 0
  /// Clicking the pill during a toggle session stops it.
  var onStopRequested: () -> Void = {}
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
@MainActor
final class IndicatorPanelController {
  private static let contentSize = NSSize(width: 260, height: 64)
  private static let shadowMargin: CGFloat = 30
  private static let bottomInset: CGFloat = 24

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

  private func position() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - panel.frame.width / 2,
      y: visible.minY + Self.bottomInset - Self.shadowMargin)
    panel.setFrameOrigin(origin)
  }
}

// MARK: - View

struct IndicatorView: View {
  let model: IndicatorModel

  var body: some View {
    content
      .frame(width: 260, height: 64)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
          .shadow(color: .black.opacity(0.35), radius: 14, y: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(borderColor, lineWidth: borderWidth))
      .padding(30)
      .animation(.easeOut(duration: 0.15), value: model.display)
      .opacity(model.display == .hidden ? 0 : 1)
      .contentShape(Rectangle())
      .onTapGesture {
        if case .recording(.toggle) = model.display { model.onStopRequested() }
      }
  }

  /// Toggle mode gets a persistent accent border so the two recording modes
  /// can never be confused.
  private var borderColor: Color {
    if case .recording(.toggle) = model.display { return .orange }
    return .white.opacity(0.08)
  }

  private var borderWidth: CGFloat {
    if case .recording(.toggle) = model.display { return 2 }
    return 1
  }

  @ViewBuilder
  private var content: some View {
    switch model.display {
    case .hidden:
      EmptyView()
    case .recording(let mode):
      HStack(spacing: 12) {
        LevelMeter(level: model.audioLevel)
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
        ProgressView().controlSize(.small)
        Text("Transcribing — \(engine)")
          .font(.system(size: 13, weight: .medium))
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
    case .clipboardFallback:
      HStack(spacing: 8) {
        Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.yellow)
        Text("Saved to history, copied to clipboard")
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
        ProgressView().controlSize(.small)
        Text("Polishing — \(style)")
          .font(.system(size: 13, weight: .medium))
      }
    }
  }

  private var elapsedLabel: String {
    String(format: "%d:%02d", model.elapsedSeconds / 60, model.elapsedSeconds % 60)
  }
}

/// Live input level, drawn as a small bar cluster that responds to the
/// actual RMS level — informative, not decorative.
private struct LevelMeter: View {
  let level: Float

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<5, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.accentColor)
          .frame(width: 3, height: barHeight(index))
      }
    }
    .frame(width: 30, height: 28)
    .animation(.linear(duration: 0.05), value: level)
  }

  private func barHeight(_ index: Int) -> CGFloat {
    let weights: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
    let scaled = CGFloat(min(1, level * 1.4) * weights[index])
    return max(4, 26 * scaled)
  }
}
