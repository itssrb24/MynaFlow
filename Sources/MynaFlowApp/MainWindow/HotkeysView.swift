import MynaFlowCore
import SwiftUI

struct HotkeysView: View {
  let coordinator: AppCoordinator
  @State private var conflict: String?

  var body: some View {
    Page(title: "Hotkeys", subtitle: "Every shortcut works in every app. Nothing steals focus.") {
      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Dictation")
        row(.dictationHold, note: "Recording starts on key down, ends on key up.")
        row(.dictationToggle, note: "Press to start, press again to stop. Auto-stops after 10 minutes.")
        row(.cancel, note: "Discards the current dictation (or a polish still thinking).")
        row(.undoLast, note: "⌘Z in the app that just received a dictation (within 90 seconds).")
        row(.reinsertLast, note: "Puts your most recent dictation at the cursor again.")
        row(.openScratchpad, note: "Opens a floating note you can dictate into, then paste anywhere.")
        row(.flagMoment, note: "While meeting notes record, marks the last 40 seconds as important for the summary.")
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Polish styles")
        ForEach(coordinator.styles) { style in
          styleRow(style)
        }
        Text("Select text in any app and press a style's shortcut to rewrite it. Up to five styles can have one.")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
        Text("⌃-based chords are recommended: the global monitor observes keys and cannot swallow them, so ⌥-chords would type a character over your selection.")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
      }
      .raised()

      if let conflict {
        Text(conflict).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.danger)
      }
    }
  }

  private func row(_ action: HotkeyAction, note: String) -> some View {
    HStack(alignment: .center, spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(action.displayName)
          .font(Theme.Fonts.bodyStrong)
          .foregroundStyle(Theme.Colors.textPrimary)
        Text(note)
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
      }
      Spacer()
      if let shortcut = coordinator.hotkeyConfiguration[action] {
        HotkeyRecorder(shortcut: shortcut) { captured in
          apply(captured, to: action)
        }
        Button {
          coordinator.updateHotkey(action, shortcut: nil)
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.textTertiary)
        .help("Unbind")
      } else {
        HotkeyRecorder(
          shortcut: HotkeyShortcut(keyCode: 0, modifiers: 0, keyLabel: "Unbound")
        ) { captured in
          apply(captured, to: action)
        }
      }
    }
  }

  private func apply(_ shortcut: HotkeyShortcut, to action: HotkeyAction) {
    if coordinator.hotkeyConfiguration.conflicts(replacing: action, with: shortcut) {
      conflict = "\(shortcut.displayName) is already used by another action."
      return
    }
    conflict = nil
    coordinator.updateHotkey(action, shortcut: shortcut)
  }

  /// One row per style, named after it; the slot behind it never shows.
  private func styleRow(_ style: Style) -> some View {
    let current = coordinator.shortcut(for: style)
    return HStack(alignment: .center, spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(style.name)
          .font(Theme.Fonts.bodyStrong)
          .foregroundStyle(Theme.Colors.textPrimary)
        Text(style.builtin ? "Built-in style" : "Custom style")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
      }
      Spacer()
      HotkeyRecorder(
        shortcut: current ?? HotkeyShortcut(keyCode: 0, modifiers: 0, keyLabel: "Unbound")
      ) { captured in
        Task { conflict = await coordinator.setStyleShortcut(captured, for: style.id) }
      }
      if current != nil {
        Button {
          Task { conflict = await coordinator.setStyleShortcut(nil, for: style.id) }
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.textTertiary)
        .help("Unbind")
      }
    }
  }
}
