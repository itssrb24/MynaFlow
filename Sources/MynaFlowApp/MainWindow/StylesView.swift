import MynaFlowCore
import SwiftUI

struct StylesView: View {
  let coordinator: AppCoordinator
  @State private var selectedID: UUID?
  @State private var draft: Style?
  @State private var saveError: String?
  @State private var shortcutError: String?

  var body: some View {
    Page(title: "Styles", subtitle: "How polish rewrites your words. Three built-ins, unlimited custom.") {
      AutoPolishCard(coordinator: coordinator)
      HStack(alignment: .top, spacing: Theme.Spacing.lg) {
        list.frame(width: 240)
        editor.frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .task {
      await coordinator.refreshStyles()
      if selectedID == nil, let first = coordinator.styles.first {
        select(first)
      }
    }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      SectionLabel(text: "Styles")
      VStack(spacing: 2) {
        ForEach(coordinator.styles) { style in
          Button {
            select(style)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(style.name)
                  .font(Theme.Fonts.bodyStrong)
                  .foregroundStyle(
                    selectedID == style.id ? Theme.Colors.accent : Theme.Colors.textPrimary)
                if style.builtin {
                  Text("Built-in")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                }
              }
              Spacer()
              if let shortcut = coordinator.shortcut(for: style) {
                Keycap(label: shortcut.keycapLabel)
              }
            }
            .padding(.horizontal, Theme.Spacing.sm + 2)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedID == style.id ? Theme.Colors.surface : .clear))
          }
          .buttonStyle(.plain)
        }
      }
      .inset(padding: Theme.Spacing.xs)
      Button {
        let style = Style(name: "New style", prompt: "Rewrite the text to …")
        draft = style
        selectedID = style.id
      } label: {
        Label("New style", systemImage: "plus")
      }
      .buttonStyle(NeuButtonStyle())
    }
  }

  @ViewBuilder
  private var editor: some View {
    if let bound = Binding($draft) {
      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Name")
        NeuTextField(placeholder: "Style name", text: bound.name)

        SectionLabel(text: "Instruction")
        TextEditor(text: bound.prompt)
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textPrimary)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 110)
          .inset(padding: Theme.Spacing.sm)

        SectionLabel(text: "Examples (optional)")
        ForEach(bound.examples.indices, id: \.self) { index in
          HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            VStack(spacing: Theme.Spacing.xs) {
              NeuTextField(placeholder: "Original", text: bound.examples[index].input)
              NeuTextField(placeholder: "Rewritten", text: bound.examples[index].output)
            }
            Button {
              draft?.examples.remove(at: index)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.textTertiary)
          }
        }
        Button("Add example") {
          draft?.examples.append(StyleExample(input: "", output: ""))
        }
        .buttonStyle(NeuButtonStyle())

        SectionLabel(text: "Shortcut")
        shortcutRow(for: bound.wrappedValue)

        if let saveError {
          Text(saveError).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.danger)
        }
        HStack {
          Button("Apply to selection") {
            if let draft { coordinator.polishExternalSelection(style: draft) }
          }
          .buttonStyle(NeuButtonStyle())
          .disabled(!coordinator.polishAvailable)
          .help("Returns to the app you came from and polishes its selection")
          Button("Save") {
            guard let draft else { return }
            Task {
              do {
                try await coordinator.saveStyle(draft)
                saveError = nil
                await coordinator.refreshStyles()
              } catch {
                saveError = error.localizedDescription
              }
            }
          }
          .buttonStyle(NeuButtonStyle(prominent: true))
          .disabled((draft?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            || (draft?.prompt.trimmingCharacters(in: .whitespaces).isEmpty ?? true))
          if draft?.builtin == false {
            Button("Delete") {
              guard let id = draft?.id else { return }
              Task {
                await coordinator.deleteStyle(id: id)
                await coordinator.refreshStyles()
                draft = nil
                selectedID = nil
              }
            }
            .buttonStyle(NeuButtonStyle(destructive: true))
          }
        }
      }
      .raised()
    } else {
      Text("Select a style to edit it.")
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Colors.textTertiary)
        .frame(maxWidth: .infinity, minHeight: 200)
        .inset()
    }
  }

  /// Click, press keys, done — the slot behind it is picked for you.
  @ViewBuilder
  private func shortcutRow(for style: Style) -> some View {
    let isSaved = coordinator.styles.contains { $0.id == style.id }
    let current = coordinator.styles.first { $0.id == style.id }.flatMap(coordinator.shortcut(for:))
    HStack(spacing: Theme.Spacing.sm) {
      HotkeyRecorder(
        shortcut: current ?? HotkeyShortcut(keyCode: 0, modifiers: 0, keyLabel: "Record shortcut")
      ) { captured in
        setShortcut(captured, for: style.id)
      }
      .disabled(!isSaved)
      if current != nil {
        Button {
          setShortcut(nil, for: style.id)
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.textTertiary)
        .help("Remove shortcut")
        .accessibilityLabel("Remove shortcut")
      }
    }
    Text(
      shortcutError
        ?? (isSaved
          ? "Select text in any app and press it to rewrite the selection in this style."
          : "Save the style first, then record its shortcut.")
    )
    .font(Theme.Fonts.caption)
    .foregroundStyle(shortcutError == nil ? Theme.Colors.textTertiary : Theme.Colors.danger)
  }

  private func setShortcut(_ shortcut: HotkeyShortcut?, for styleID: UUID) {
    Task {
      shortcutError = await coordinator.setStyleShortcut(shortcut, for: styleID)
      // Keep the open draft's slot in step, so Save can't put back an old one.
      draft?.hotkeySlot = coordinator.styles.first { $0.id == styleID }?.hotkeySlot
    }
  }

  private func select(_ style: Style) {
    selectedID = style.id
    draft = style
    saveError = nil
    shortcutError = nil
  }
}

/// "Polish every dictation with …": off unless the user picks a style. Says
/// plainly when no model is installed, since the choice then does nothing.
private struct AutoPolishCard: View {
  let coordinator: AppCoordinator

  var body: some View {
    HStack(alignment: .center, spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Polish every dictation")
          .font(Theme.Fonts.bodyStrong)
          .foregroundStyle(Theme.Colors.textPrimary)
        Text(note)
          .font(Theme.Fonts.caption)
          .foregroundStyle(
            coordinator.autoPolishStyleID != nil && !coordinator.polishAvailable
              ? Theme.Colors.warning : Theme.Colors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Theme.Spacing.md)
      Picker("Style", selection: selection) {
        Text("Off").tag(UUID?.none)
        Divider()
        ForEach(coordinator.styles) { style in
          Text(style.name).tag(UUID?.some(style.id))
        }
      }
      .labelsHidden()
      .frame(width: 180)
    }
    .raised()
  }

  private var selection: Binding<UUID?> {
    Binding(
      get: { coordinator.autoPolishStyleID },
      set: { coordinator.setAutoPolishStyle($0) })
  }

  private var note: String {
    if coordinator.autoPolishStyleID == nil {
      return "Off: dictations are cleaned up (filler words, punctuation) but not rewritten."
    }
    if !coordinator.polishAvailable {
      return "Needs a polish model — install one in Models. Until then, dictations are only cleaned up."
    }
    return "Each dictation is rewritten on this Mac before it's typed, adding a second or two. If polishing fails, the cleaned text is typed instead."
  }
}
