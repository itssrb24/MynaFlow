import MynaFlowCore
import SwiftUI

/// One row per app you have dictated into (plus any app with a rule). Every
/// control defaults to "Default" so a rule only exists where you changed
/// something.
struct AppRulesView: View {
  let coordinator: AppCoordinator
  @State private var bundleIDs: [String] = []

  var body: some View {
    Page(title: "Apps", subtitle: "Dictate differently per app: skip cleanup, drop the trailing period, rewrite in a style, or paste into editors Accessibility cannot see.") {
      if bundleIDs.isEmpty {
        Text("Apps appear here after you dictate into them.")
          .font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textTertiary)
          .frame(maxWidth: .infinity, minHeight: 120)
          .inset()
      } else {
        VStack(spacing: Theme.Spacing.sm) {
          ForEach(bundleIDs, id: \.self) { bundleID in
            AppRuleRow(
              bundleID: bundleID,
              rule: coordinator.appRules.first { $0.bundleID == bundleID } ?? AppRule(bundleID: bundleID),
              styles: coordinator.styles,
              polishAvailable: coordinator.polishAvailable
            ) { coordinator.saveAppRule($0) }
          }
        }
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          Text("Auto-polish runs the local model on every dictation into that app, adding a few seconds. If the model is unavailable the cleaned text is inserted as-is.")
          Text("Paste turns on pasting for apps that hide their text field from Accessibility — Google Docs draws its page on a canvas, so nothing else reaches it. Myna Flow cannot check an invisible field for being a password field, so leave this off for apps where you type passwords.")
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.Colors.textTertiary)
      }
    }
    .task { await reload() }
  }

  private func reload() async {
    let history = await coordinator.historyApps()
    let ruled = coordinator.appRules.map(\.bundleID)
    bundleIDs = Array(Set(history + ruled)).sorted { AppNames.display($0) < AppNames.display($1) }
  }
}

private struct AppRuleRow: View {
  let bundleID: String
  let rule: AppRule
  let styles: [Style]
  let polishAvailable: Bool
  let save: (AppRule) -> Void

  var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(AppNames.display(bundleID)).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
        Text(bundleID).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      TriStatePicker(label: "Cleanup", value: rule.cleanupEnabled) { changed in
        var updated = rule
        updated.cleanupEnabled = changed
        save(updated)
      }
      TriStatePicker(label: "Period", value: rule.terminalPeriod) { changed in
        var updated = rule
        updated.terminalPeriod = changed
        save(updated)
      }
      TriStatePicker(label: "Paste", value: rule.pasteWhenUnseen) { changed in
        var updated = rule
        updated.pasteWhenUnseen = changed
        save(updated)
      }
      Picker("Auto-polish", selection: Binding(
        get: { rule.polishStyleID },
        set: { id in
          var updated = rule
          updated.polishStyleID = id
          save(updated)
        })
      ) {
        Text("No auto-polish").tag(UUID?.none)
        ForEach(styles) { Text($0.name).tag(UUID?.some($0.id)) }
      }
      .labelsHidden()
      .frame(width: 170)
      .disabled(!polishAvailable)
      .help(polishAvailable ? "" : "Install the polish model on the Models page first")
    }
    .raised(padding: Theme.Spacing.md)
  }
}

/// Default / On / Off, where Default means "use the global setting".
private struct TriStatePicker: View {
  let label: String
  let value: Bool?
  let onChange: (Bool?) -> Void

  var body: some View {
    Picker(label, selection: Binding(
      get: { value == nil ? 0 : (value == true ? 1 : 2) },
      set: { onChange($0 == 0 ? nil : $0 == 1) })
    ) {
      Text("\(label): default").tag(0)
      Text("\(label): on").tag(1)
      Text("\(label): off").tag(2)
    }
    .labelsHidden()
    .frame(width: 150)
  }
}
