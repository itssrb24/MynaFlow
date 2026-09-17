import SwiftUI

struct AudioView: View {
  let coordinator: AppCoordinator
  @State private var fillerText = ""

  var body: some View {
    Page(title: "Audio & General", subtitle: "Microphone, cleanup, and startup.") {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        SectionLabel(text: "Startup")
        Toggle(isOn: Binding(
          get: { coordinator.launchAtLogin },
          set: { coordinator.setLaunchAtLogin($0) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Launch at login").font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
            Text("Myna Flow is a menu bar app; it only helps when it's running.")
              .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
          }
        }
        .toggleStyle(.switch)
        .tint(Theme.Colors.accent)
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        SectionLabel(text: "Input device")
        deviceRow(uid: nil, name: "System default", detail: "Follows macOS when you change inputs.")
        ForEach(coordinator.inputDevices) { device in
          deviceRow(uid: device.uid, name: device.name, detail: nil)
        }
        Button {
          coordinator.refreshInputDevices()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(NeuButtonStyle())
        .padding(.top, Theme.Spacing.sm)
      }
      .raised()
      .task { coordinator.refreshInputDevices() }

      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        SectionLabel(text: "Cleanup")
        Toggle(isOn: Binding(
          get: { coordinator.cleanupEnabled },
          set: { coordinator.setCleanupEnabled($0) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Clean up filler words and stutters")
              .font(Theme.Fonts.bodyStrong)
              .foregroundStyle(Theme.Colors.textPrimary)
            Text("Removes “um”, “uh”, repeated words, and false starts without changing meaning. Off gives the raw transcript.")
              .font(Theme.Fonts.caption)
              .foregroundStyle(Theme.Colors.textTertiary)
          }
        }
        .toggleStyle(.switch)
        .tint(Theme.Colors.accent)

        SectionLabel(text: "Your filler words")
        HStack(spacing: Theme.Spacing.sm) {
          NeuTextField(placeholder: "basically, right, so yeah", text: $fillerText)
            .onSubmit { coordinator.setUserFillers(fillerText) }
          Button("Save") { coordinator.setUserFillers(fillerText) }
            .buttonStyle(NeuButtonStyle())
        }
        Text("Comma-separated. Added to the built-in list (um, uh, er…). Vocabulary terms are never treated as fillers.")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Indicator")
        Picker("Position", selection: Binding(
          get: { coordinator.indicatorPlacement },
          set: { coordinator.setIndicatorPlacement($0) })
        ) {
          ForEach(IndicatorPlacement.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        Text("Shown on the screen with the app you're dictating into.")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        Toggle(isOn: Binding(
          get: { coordinator.soundFeedback },
          set: { coordinator.setSoundFeedback($0) })
        ) {
          Text("Sound on start and stop").font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(Theme.Colors.accent)
        HStack(spacing: Theme.Spacing.sm) {
          Text("Toggle mode auto-stops after").font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
          Stepper(
            "\(coordinator.toggleMaximumMinutes) min",
            value: Binding(
              get: { coordinator.toggleMaximumMinutes },
              set: { coordinator.setToggleMaximumMinutes($0) }),
            in: 1...60)
            .font(Theme.Fonts.mono).foregroundStyle(Theme.Colors.textPrimary)
        }
      }
      .raised()
    }
    .task { fillerText = coordinator.userFillers.joined(separator: ", ") }
  }

  private func deviceRow(uid: String?, name: String, detail: String?) -> some View {
    let selected = coordinator.selectedInputUID == uid
    return Button {
      coordinator.selectInputDevice(uid: uid)
    } label: {
      HStack(spacing: Theme.Spacing.md) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.textTertiary)
        VStack(alignment: .leading, spacing: 2) {
          Text(name)
            .font(Theme.Fonts.bodyStrong)
            .foregroundStyle(Theme.Colors.textPrimary)
          if let detail {
            Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
          }
        }
        Spacer()
      }
      .padding(.vertical, Theme.Spacing.xs)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
