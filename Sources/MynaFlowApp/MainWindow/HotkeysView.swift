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
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Polish styles")
        ForEach(HotkeyAction.styleActions, id: \.self) { action in
          row(action, note: styleNote(for: action))
        }
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

  private func styleNote(for action: HotkeyAction) -> String {
    guard let slot = action.styleSlot else { return "" }
    if let style = coordinator.styles.first(where: { $0.hotkeySlot == slot }) {
      return "Polishes the selection as “\(style.name)”."
    }
    return "No style assigned — pick one in Styles."
  }
}
