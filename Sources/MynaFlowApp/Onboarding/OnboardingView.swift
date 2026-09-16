import AVFoundation
import MynaFlowCore
import SwiftUI

/// First run → first successful dictation, under 90 seconds. Eight steps,
/// each one thing; step 8 is not optional.
struct OnboardingView: View {
  let coordinator: AppCoordinator
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var step = 0
  @State private var previewLevel: Float = 0
  @State private var testText = ""
  @State private var testResult: String?
  @State private var typingWPMText = "40"
  @State private var firstDictationText = ""
  @State private var dictationCountAtStart = 0

  private let stepTitles = [
    "Welcome", "Microphone", "Accessibility", "Input", "Typing speed", "Polish model",
    "Hotkeys", "First dictation",
  ]

  var body: some View {
    VStack(spacing: 0) {
      progress
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Spacing.xl)
      footer
    }
    .frame(width: 640, height: 520)
    .background(Theme.Colors.base)
    .preferredColorScheme(.dark)
    .onChange(of: step) { _, newValue in
      coordinator.stopLevelPreview()
      if newValue == 1 { coordinator.startLevelPreview { previewLevel = $0 } }
      if newValue == 7 { dictationCountAtStart = coordinator.recentDictations.count }
    }
    .onDisappear { coordinator.stopLevelPreview() }
  }

  private var progress: some View {
    HStack(spacing: Theme.Spacing.xs) {
      ForEach(stepTitles.indices, id: \.self) { index in
        RoundedRectangle(cornerRadius: 2)
          .fill(index <= step ? Theme.Colors.accent : Theme.Colors.surface)
          .frame(height: 3)
      }
    }
    .padding(.horizontal, Theme.Spacing.xl)
    .padding(.top, Theme.Spacing.lg)
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case 0:
      page("Welcome to Myna Flow", "Hold a key, talk, release. Your words land where your cursor is — transcribed on this Mac, never sent anywhere.") {
        Text("Two permissions, a microphone, one shortcut, one sentence. Under 90 seconds.")
          .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
      }
    case 1:
      page("Microphone", "Myna Flow records only while you hold or toggle the dictation shortcut.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          if coordinator.microphoneGranted {
            HStack(spacing: Theme.Spacing.md) {
              PreviewMeter(level: previewLevel)
              Text("Say something — the meter should move.")
                .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            }
          } else {
            Button("Allow microphone access") { Task { await coordinator.requestMicrophone() } }
              .buttonStyle(NeuButtonStyle(prominent: true))
          }
        }
      }
    case 2:
      page("Accessibility", "This is how dictated text is placed at your cursor in other apps.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          if coordinator.accessibilityGranted {
            Text("Click the field, then press Test — a sentence should appear.")
              .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            HStack(spacing: Theme.Spacing.sm) {
              NeuTextField(placeholder: "Click here", text: $testText)
              Button("Test insertion") {
                Task { testResult = await coordinator.testInsertion() }
              }
              .buttonStyle(NeuButtonStyle(prominent: true))
            }
            if let testResult {
              Text(testResult).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
            }
          } else {
            Text("macOS will open System Settings → Privacy & Security → Accessibility. Turn on Myna Flow, then come back.")
              .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            Button("Open Accessibility settings") { coordinator.requestAccessibility() }
              .buttonStyle(NeuButtonStyle(prominent: true))
            Button("I've turned it on") { coordinator.refreshPermissions() }
              .buttonStyle(NeuButtonStyle())
          }
        }
      }
    case 3:
      page("Input", "Which microphone to listen to.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
          deviceRow(uid: nil, name: "System default")
          ForEach(coordinator.inputDevices) { deviceRow(uid: $0.uid, name: $0.name) }
        }
        .task { coordinator.refreshInputDevices() }
      }
    case 4:
      page("Typing speed", "Used only for the “time saved” number in Insights. Skip if you don't know.") {
        HStack(spacing: Theme.Spacing.sm) {
          TextField("40", text: $typingWPMText)
            .textFieldStyle(.plain).font(Theme.Fonts.display)
            .foregroundStyle(Theme.Colors.textPrimary).frame(width: 90)
            .inset(padding: Theme.Spacing.sm)
          Text("words per minute").font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
        }
      }
    case 5:
      page("Polish model", "Dictation works with nothing downloaded. Polish — rewriting a selection in a style — needs a local language model.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          if let model = coordinator.polishModel {
            Text("Recommended for this Mac: \(model.displayName) (\(model.sizeLabel)). Loads on first polish, unloads when idle.")
              .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
            if coordinator.polishModelInstalled {
              Text("Installed.").font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.success)
            } else if let fraction = coordinator.polishDownloadFraction {
              ProgressView(value: fraction).frame(width: 240)
              Text("Downloading — you can continue; it finishes in the background.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
            } else {
              Button("Download \(model.displayName)") { coordinator.installPolishModel() }
                .buttonStyle(NeuButtonStyle(prominent: true))
            }
          } else {
            Text("No language model fits this Mac comfortably. Dictation is unaffected.")
              .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
          }
          Text("Skipping is fine. You can install it later from Models.")
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
      }
    case 6:
      page("Hotkeys", "Defaults shown. Click one to remap it now, or change it later.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          hotkeyRow(.dictationHold)
          hotkeyRow(.dictationToggle)
          hotkeyRow(.style1)
        }
      }
    default:
      page("Your first dictation", "Click the field below, hold \(coordinator.hotkeyConfiguration[.dictationHold]?.keycapLabel ?? "the shortcut"), say a sentence, release.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          TextEditor(text: $firstDictationText)
            .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
            .scrollContentBackground(.hidden)
            .frame(height: 120)
            .inset(padding: Theme.Spacing.sm)
          if firstDictationSucceeded {
            HStack(spacing: Theme.Spacing.sm) {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.success)
              Text("That's it. Myna Flow lives in your menu bar.")
                .font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
            }
          } else {
            Text("Waiting for your first dictation…")
              .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
          }
        }
      }
    }
  }

  private var firstDictationSucceeded: Bool {
    !firstDictationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || coordinator.recentDictations.count > dictationCountAtStart
  }

  private var footer: some View {
    HStack {
      Text("Step \(step + 1) of \(stepTitles.count) · \(stepTitles[step])")
        .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      Spacer()
      if step > 0 {
        Button("Back") { step -= 1 }.buttonStyle(NeuButtonStyle())
      }
      if step < stepTitles.count - 1 {
        Button(step == 4 || step == 5 ? "Skip" : "Continue") { advance() }
          .buttonStyle(NeuButtonStyle(prominent: canAdvance))
          .disabled(!canAdvance)
      } else {
        Button("Finish") {
          coordinator.completeOnboarding()
          dismissWindow(id: "onboarding")
        }
        .buttonStyle(NeuButtonStyle(prominent: true))
        .disabled(!firstDictationSucceeded)
      }
    }
    .padding(Theme.Spacing.lg)
    .background(Theme.Colors.well)
  }

  private var canAdvance: Bool {
    switch step {
    case 1: coordinator.microphoneGranted
    case 2: coordinator.accessibilityGranted
    default: true
    }
  }

  private func advance() {
    if step == 4, let value = Double(typingWPMText), value > 0 {
      coordinator.setTypingWPM(value)
    }
    step += 1
  }

  private func page<Content: View>(
    _ title: String, _ subtitle: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
      Text(title).font(Theme.Fonts.display).foregroundStyle(Theme.Colors.textPrimary)
      Text(subtitle).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      content()
    }
  }

  private func deviceRow(uid: String?, name: String) -> some View {
    let selected = coordinator.selectedInputUID == uid
    return Button {
      coordinator.selectInputDevice(uid: uid)
    } label: {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.textTertiary)
        Text(name).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func hotkeyRow(_ action: HotkeyAction) -> some View {
    HStack {
      Text(action.displayName).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
      Spacer()
      HotkeyRecorder(
        shortcut: coordinator.hotkeyConfiguration[action]
          ?? HotkeyShortcut(keyCode: 0, modifiers: 0, keyLabel: "Unbound")
      ) { captured in
        guard !coordinator.hotkeyConfiguration.conflicts(replacing: action, with: captured) else { return }
        coordinator.updateHotkey(action, shortcut: captured)
      }
    }
  }
}

private struct PreviewMeter: View {
  let level: Float

  var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<12, id: \.self) { index in
        RoundedRectangle(cornerRadius: 2)
          .fill(Float(index) / 12 < min(1, level * 1.5) ? Theme.Colors.accent : Theme.Colors.surface)
          .frame(width: 8, height: 28)
      }
    }
    .animation(.linear(duration: 0.05), value: level)
  }
}
