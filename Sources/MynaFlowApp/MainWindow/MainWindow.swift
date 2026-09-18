import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
  case insights, history, styles, apps, vocabulary, learning, hotkeys, audio, models
  var id: String { rawValue }

  var title: String {
    switch self {
    case .insights: "Insights"
    case .history: "History"
    case .styles: "Styles"
    case .apps: "Apps"
    case .vocabulary: "Vocabulary"
    case .learning: "Learning"
    case .hotkeys: "Hotkeys"
    case .audio: "Audio"
    case .models: "Models"
    }
  }

  var symbol: String {
    switch self {
    case .insights: "chart.bar.xaxis"
    case .history: "clock.arrow.circlepath"
    case .styles: "wand.and.sparkles"
    case .apps: "macwindow.on.rectangle"
    case .vocabulary: "character.book.closed"
    case .learning: "brain"
    case .hotkeys: "keyboard"
    case .audio: "mic"
    case .models: "cpu"
    }
  }
}

struct MainWindowView: View {
  let coordinator: AppCoordinator
  @State private var section: MainSection = .insights

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .background(Theme.Colors.base)
    .preferredColorScheme(.dark)
    .frame(minWidth: 860, minHeight: 560)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      Text("Myna Flow")
        .font(Theme.Fonts.title)
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
      ForEach(MainSection.allCases) { item in
        SidebarRow(section: item, selected: item == section) {
          withAnimation(Theme.Motion.ease) { section = item }
        }
      }
      Spacer()
      Text("Local only · nothing leaves this Mac")
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.Colors.textTertiary)
        .padding(Theme.Spacing.md)
    }
    .frame(width: 196)
    .padding(.horizontal, Theme.Spacing.sm)
    .background(Theme.Colors.well)
    .overlay(alignment: .trailing) {
      Rectangle().fill(Theme.Colors.hairline).frame(width: 1)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch section {
    case .insights: InsightsView(coordinator: coordinator)
    case .history: HistoryView(coordinator: coordinator)
    case .styles: StylesView(coordinator: coordinator)
    case .apps: AppRulesView(coordinator: coordinator)
    case .vocabulary: VocabularyView(coordinator: coordinator)
    case .learning: LearningView(coordinator: coordinator)
    case .hotkeys: HotkeysView(coordinator: coordinator)
    case .audio: AudioView(coordinator: coordinator)
    case .models: ModelsView(coordinator: coordinator)
    }
  }
}

private struct SidebarRow: View {
  let section: MainSection
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.sm + 2) {
        Image(systemName: section.symbol)
          .font(.system(size: 13, weight: .medium))
          .frame(width: 18)
        Text(section.title)
          .font(Theme.Fonts.bodyStrong)
        Spacer()
      }
      .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.textSecondary)
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.vertical, Theme.Spacing.sm + 2)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
          .fill(selected ? Theme.Colors.surface : (hovering ? Theme.Colors.surface.opacity(0.5) : .clear))
          .shadow(color: selected ? Theme.Colors.shade : .clear, radius: 8, x: 3, y: 3)
          .shadow(color: selected ? Theme.Colors.highlight : .clear, radius: 6, x: -2, y: -2))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

/// Standard page frame: display title, subtitle, scrolling body.
struct Page<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          Text(title)
            .font(Theme.Fonts.display)
            .foregroundStyle(Theme.Colors.textPrimary)
          Text(subtitle)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.bottom, Theme.Spacing.sm)
        content
      }
      .padding(Theme.Spacing.xl)
      .frame(maxWidth: 760, alignment: .leading)
    }
  }
}
