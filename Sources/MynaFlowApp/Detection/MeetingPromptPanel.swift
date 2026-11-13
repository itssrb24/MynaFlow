import AppKit
import SwiftUI

/// What the meeting prompt says and does. Text only — the controller owns
/// the actions and the timeout.
struct MeetingPromptContent: Equatable {
  enum Tone: Equatable { case start, stop }

  /// The meeting or app — truncated in the middle so both ends stay.
  let title: String
  /// "Zoom · on a call", "Starts at 2:00 PM · video call".
  let subtitle: String
  let detail: String
  let primary: String
  let secondary: String
  let tone: Tone
  /// Shown as a countdown; when it reaches zero the controller acts.
  let timeoutLabel: String
}

@MainActor
@Observable
final class MeetingPromptModel {
  var content: MeetingPromptContent?
  var secondsLeft = 0
  var totalSeconds = 60
  @ObservationIgnored var onPrimary: () -> Void = {}
  @ObservationIgnored var onSecondary: () -> Void = {}
}

/// A small card at the top right of the screen, where macOS notifications
/// appear, asking about meeting notes. It
/// never takes focus from the call the user is joining.
@MainActor
final class MeetingPromptPanelController {
  static let size = NSSize(width: 380, height: 148)
  /// From the menu bar and the right edge, matching notification banners.
  private static let topInset: CGFloat = 12
  private static let rightInset: CGFloat = 12

  let model = MeetingPromptModel()
  private let panel: NSPanel

  init() {
    panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    // It names the meeting just as a call (and maybe a screen share) begins.
    panel.sharingType = .none
    panel.contentView = NSHostingView(rootView: MeetingPromptView(model: model))
  }

  var isVisible: Bool { panel.isVisible }

  func show() {
    let screen = NSScreen.main ?? NSScreen.screens.first
    if let frame = screen?.visibleFrame {
      panel.setFrameOrigin(
        NSPoint(
          x: frame.maxX - Self.size.width - Self.rightInset,
          y: frame.maxY - Self.size.height - Self.topInset))
    }
    panel.orderFrontRegardless()
    // The panel never takes focus, so VoiceOver would not notice it.
    if let content = model.content {
      NSAccessibility.post(
        element: NSApp as Any, notification: .announcementRequested,
        userInfo: [
          .announcement: "\(content.title). \(content.detail)",
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
  }

  func hide() {
    panel.orderOut(nil)
    model.content = nil
  }
}

private struct MeetingPromptView: View {
  let model: MeetingPromptModel

  var body: some View {
    if let content = model.content {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
          Image(systemName: content.tone == .start ? "person.2.wave.2" : "phone.down")
            .foregroundStyle(content.tone == .start ? Theme.Colors.accent : Theme.Colors.warning)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            Text(content.title)
              .font(Theme.Fonts.bodyStrong)
              .foregroundStyle(Theme.Colors.textPrimary)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(content.subtitle)
              .font(Theme.Fonts.caption)
              .foregroundStyle(Theme.Colors.textSecondary)
              .lineLimit(1)
          }
        }
        Text(content.detail)
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textSecondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        HStack {
          Text("\(content.timeoutLabel) \(model.secondsLeft) s")
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .monospacedDigit()
          Spacer()
          Button(content.secondary) { model.onSecondary() }
            .buttonStyle(NeuButtonStyle())
          // No keyboard shortcut: the panel never takes focus, and a Return
          // typed into the call must never answer it.
          Button(content.primary) { model.onPrimary() }
            .buttonStyle(NeuButtonStyle(prominent: true))
        }
      }
      .padding(Theme.Spacing.md)
      .frame(
        width: MeetingPromptPanelController.size.width,
        height: MeetingPromptPanelController.size.height)
      .background(card)
      .overlay(alignment: .bottom) { countdownBar }
      .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(content.title)
    }
  }

  /// The house raised-card edge: light top-left, shade bottom-right.
  private var card: some View {
    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
      .fill(Theme.Colors.surface)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [Theme.Colors.highlight, Theme.Colors.hairline, Theme.Colors.shade.opacity(0.4)],
              startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 1))
  }

  /// Time left, at a glance: shrinks to nothing as the countdown runs out.
  private var countdownBar: some View {
    GeometryReader { proxy in
      let fraction = Double(model.secondsLeft) / Double(max(model.totalSeconds, 1))
      Rectangle()
        .fill((model.content?.tone == .stop ? Theme.Colors.warning : Theme.Colors.accent).opacity(0.7))
        .frame(width: proxy.size.width * fraction, height: 2)
        .animation(.linear(duration: 1), value: model.secondsLeft)
    }
    .frame(height: 2)
    .accessibilityHidden(true)
  }
}
