import MynaFlowCore
import SwiftUI

struct LearningView: View {
  let coordinator: AppCoordinator

  var body: some View {
    Page(title: "Learning", subtitle: "Habits noticed in your edits, proposed as rules. Nothing applies until you approve it — and the switch is on.") {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        Toggle(isOn: Binding(
          get: { coordinator.learningEnabled },
          set: { coordinator.setLearningEnabled($0) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Apply approved rules to new dictations")
              .font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
            Text(coordinator.learningEnabled
              ? "On. Approved rules run after cleanup."
              : "Off. Suggestions keep accumulating; approved rules stay inert.")
              .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
          }
        }
        .toggleStyle(.switch)
        .tint(Theme.Colors.accent)
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        HStack {
          SectionLabel(text: "Suggested")
          Spacer()
          Button {
            Task { await coordinator.runLearner() }
          } label: {
            Label("Analyze now", systemImage: "sparkles")
          }
          .buttonStyle(NeuButtonStyle())
        }
        if coordinator.suggestedRules.isEmpty {
          Text("Nothing yet. Rules appear once the same edit shows up two or three times.")
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        ForEach(coordinator.suggestedRules) { stored in
          ruleRow(stored) {
            Button("Approve") { Task { await coordinator.setRuleStatus(stored.id, .approved) } }
              .buttonStyle(NeuButtonStyle(prominent: true))
            Button("Reject") { Task { await coordinator.setRuleStatus(stored.id, .rejected) } }
              .buttonStyle(NeuButtonStyle())
          }
        }
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Approved")
        if coordinator.approvedRules.isEmpty {
          Text("No approved rules.").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        ForEach(coordinator.approvedRules) { stored in
          ruleRow(stored) {
            Button("Remove") { Task { await coordinator.setRuleStatus(stored.id, .rejected) } }
              .buttonStyle(NeuButtonStyle(destructive: true))
          }
        }
      }
      .raised()
    }
    .task { await coordinator.refreshLearnedRules() }
  }

  private func ruleRow<Actions: View>(
    _ stored: StoredLearnedRule, @ViewBuilder actions: () -> Actions
  ) -> some View {
    HStack(spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(stored.rule.summary).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
        Text("\(kindLabel(stored.rule.kind)) · seen \(stored.rule.evidence)×")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      }
      Spacer()
      actions()
    }
    .padding(.vertical, Theme.Spacing.xs)
  }

  private func kindLabel(_ kind: LearnedRule.Kind) -> String {
    switch kind {
    case .filler: "Filler word"
    case .replacement: "Replacement"
    case .formatting: "Formatting"
    }
  }
}
