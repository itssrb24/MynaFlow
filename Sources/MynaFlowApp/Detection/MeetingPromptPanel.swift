import AppKit
import SwiftUI

/// What the meeting prompt says and does. Text only — the controller owns
/// the actions and the timeout.
struct MeetingPromptContent: Equatable {
  enum Tone: Equatable { case start, stop }

  let title: String
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
  @ObservationIgnored var onPrimary: () -> Void = {}
  @ObservationIgnored var onSecondary: () -> Void = {}
}

/// A small card at the top of the screen asking about meeting notes. It
/// never takes focus from the call the user is joining.
@MainActor
final class MeetingPromptPanelController {
  private static let size = NSSize(width: 380, height: 132)
  private static let topInset: CGFloat = 36

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
          x: frame.midX - Self.size.width / 2,
          y: frame.maxY - Self.size.height - Self.topInset))
    }
    panel.orderFrontRegardless()
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
        HStack(spacing: Theme.Spacing.sm) {
          Image(systemName: content.tone == .start ? "person.2.wave.2" : "phone.down")
            .foregroundStyle(content.tone == .start ? Theme.Colors.accent : Theme.Colors.warning)
          Text(content.title)
            .font(Theme.Fonts.bodyStrong)
            .foregroundStyle(Theme.Colors.textPrimary)
            .lineLimit(1)
        }
        Text(content.detail)
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textSecondary)
          .lineLimit(2)
        HStack {
          Text("\(content.timeoutLabel) \(model.secondsLeft) s")
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
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
      .frame(width: 380, height: 132)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
          .fill(Theme.Colors.surface)
          .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
              .strokeBorder(Theme.Colors.hairline)))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(content.title)
    }
  }
}
