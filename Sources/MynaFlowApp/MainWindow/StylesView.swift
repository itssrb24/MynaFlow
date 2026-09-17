import MynaFlowCore
import SwiftUI

struct StylesView: View {
  let coordinator: AppCoordinator
  @State private var selectedID: UUID?
  @State private var draft: Style?
  @State private var saveError: String?

  var body: some View {
    Page(title: "Styles", subtitle: "How polish rewrites a selection. Three built-ins, unlimited custom.") {
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
              if let slot = style.hotkeySlot,
                let shortcut = HotkeyAction.forSlot(slot).flatMap { coordinator.hotkeyConfiguration[$0] }
              {
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

        SectionLabel(text: "Hotkey slot")
        Picker("Slot", selection: bound.hotkeySlot) {
          Text("None").tag(Int?.none)
          ForEach(1...5, id: \.self) { slot in
            let label = HotkeyAction.forSlot(slot).flatMap { coordinator.hotkeyConfiguration[$0] }?.keycapLabel ?? "unbound"
            Text("Slot \(slot) · \(label)").tag(Int?.some(slot))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
        Text("Slots are bound to keys in Hotkeys. Assigning a slot here unassigns any other style using it.")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)

        if let saveError {
          Text(saveError).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.danger)
        }
        HStack {
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

  private func select(_ style: Style) {
    selectedID = style.id
    draft = style
    saveError = nil
  }
}
