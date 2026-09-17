import MynaFlowCore
import SwiftUI

struct VocabularyView: View {
  let coordinator: AppCoordinator
  @State private var newTerm = ""

  var body: some View {
    Page(title: "Vocabulary", subtitle: "Names and jargon the engine should expect. The single biggest accuracy lever.") {
      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Terms")
        HStack(spacing: Theme.Spacing.sm) {
          NeuTextField(placeholder: "Add a term (e.g. Kubernetes, Myna Flow)", text: $newTerm)
            .onSubmit { add() }
          Button("Add") { add() }
            .buttonStyle(NeuButtonStyle(prominent: true))
            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if coordinator.vocabulary.isEmpty {
          Text("No terms yet.").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        } else {
          FlowLayout(spacing: Theme.Spacing.sm) {
            ForEach(coordinator.vocabulary) { term in
              HStack(spacing: Theme.Spacing.xs) {
                Text(term.term).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
                if term.source == .promoted {
                  Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(Theme.Colors.accent)
                }
                Button {
                  Task { await coordinator.removeVocabularyTerm(term.term) }
                } label: {
                  Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.textTertiary)
              }
              .padding(.horizontal, Theme.Spacing.sm + 2)
              .padding(.vertical, Theme.Spacing.xs + 2)
              .background(
                RoundedRectangle(cornerRadius: Theme.Radius.pill).fill(Theme.Colors.surface)
                  .shadow(color: Theme.Colors.shade, radius: 4, x: 2, y: 2))
            }
          }
        }
        Text(coordinator.boostingInstalled
          ? "Passed to Apple Speech as hints and to Parakeet through vocabulary boosting. Terms are also protected from cleanup."
          : "Passed to Apple Speech as hints; install vocabulary boosting in Models for Parakeet to use them too. Terms are also protected from cleanup.")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Suggested from your corrections")
        if coordinator.corrections.isEmpty {
          Text("When you edit dictated text right after it lands, the change shows up here for review.")
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        ForEach(coordinator.corrections) { correction in
          HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: Theme.Spacing.xs) {
                Text(correction.pair.before).font(Theme.Fonts.body)
                  .foregroundStyle(Theme.Colors.textTertiary).strikethrough()
                Image(systemName: "arrow.right").font(.system(size: 9))
                  .foregroundStyle(Theme.Colors.textTertiary)
                Text(correction.pair.after).font(Theme.Fonts.bodyStrong)
                  .foregroundStyle(Theme.Colors.textPrimary)
              }
              Text(correction.observedAt.formatted(date: .abbreviated, time: .shortened))
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer()
            Button("Add to vocabulary") { Task { await coordinator.acceptCorrection(correction) } }
              .buttonStyle(NeuButtonStyle(prominent: true))
            Button("Dismiss") { Task { await coordinator.dismissCorrection(correction) } }
              .buttonStyle(NeuButtonStyle())
          }
          .padding(.vertical, Theme.Spacing.xs)
        }
      }
      .raised()
    }
    .task { await coordinator.refreshVocabulary() }
  }

  private func add() {
    let term = newTerm.trimmingCharacters(in: .whitespaces)
    guard !term.isEmpty else { return }
    newTerm = ""
    Task { await coordinator.addVocabularyTerm(term) }
  }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 600
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > width, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: width, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > bounds.maxX, x > bounds.minX {
        x = bounds.minX
        y += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
